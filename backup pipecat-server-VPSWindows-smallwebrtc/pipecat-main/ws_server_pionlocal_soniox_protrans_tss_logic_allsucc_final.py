import asyncio
import json
import logging
import re
import ssl
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import websockets

# Pipecat core
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.parallel_pipeline import ParallelPipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.frames.frames import (
    Frame, LLMRunFrame, AudioRawFrame, TextFrame, StartFrame, 
    EndFrame, CancelFrame, ErrorFrame, LLMFullResponseStartFrame, LLMFullResponseEndFrame
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.transports.base_transport import TransportParams
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection, IceServer

# Pipecat Context & Aggregators
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import LLMContextAggregatorPair

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────
# MONKEY-PATCH: Force relay-only ICE qua aioice.ice.Connection
# ──────────────────────────────────────────────────────────────
import aioice.ice as _aioice_ice

_original_gather = _aioice_ice.Connection.gather_candidates

async def _relay_only_gather(self):
    await _original_gather(self)
    before = len(self._local_candidates)
    self._local_candidates = [
        c for c in self._local_candidates if c.type == "relay"
    ]
    after = len(self._local_candidates)
    logger.info(f"ICE relay-only patch: {before} candidates → giữ {after} relay")

_aioice_ice.Connection.gather_candidates = _relay_only_gather
# ──────────────────────────────────────────────────────────────

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

pcs_map: dict[str, SmallWebRTCConnection] = {}

ICE_SERVERS = [
    IceServer(
        urls="turn:103.118.29.243:3479?transport=tcp",
        username="test",
        credential="test123",
    ),
]

def filter_sdp_relay_only(sdp: str) -> str:
    lines = sdp.split("\r\n") if "\r\n" in sdp else sdp.split("\n")
    newline = "\r\n" if "\r\n" in sdp else "\n"
    filtered = []
    
    for line in lines:
        if line.startswith("a=candidate:"):
            parts = line.split()
            if len(parts) >= 8:
                candidate_type = ""
                for i, p in enumerate(parts):
                    if p == "typ" and i + 1 < len(parts):
                        candidate_type = parts[i + 1]
                        break
                if candidate_type == "relay":
                    filtered.append(line)
            else:
                filtered.append(line)
        else:
            filtered.append(line)
    return newline.join(filtered)


def create_stt(provider: str, api_key: str, diarize: bool = False):
    if provider == "deepgram":
        from pipecat.services.deepgram.stt import DeepgramSTTService
        return DeepgramSTTService(api_key=api_key, diarize=diarize)
    elif provider == "openai":
        from pipecat.services.openai.stt import OpenAISTTService
        return OpenAISTTService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google.stt import GoogleSTTService
        return GoogleSTTService(api_key=api_key)
    else:
        raise ValueError(f"STT provider không hỗ trợ: {provider}")

def create_llm(provider: str, api_key: str, model: str):
    if provider == "openai":
        from pipecat.services.openai.llm import OpenAILLMService
        return OpenAILLMService(api_key=api_key, model=model)
    elif provider == "google":
        from pipecat.services.google.llm import GoogleLLMService
        return GoogleLLMService(api_key=api_key, model=model)
    else:
        raise ValueError(f"LLM provider không hỗ trợ: {provider}")

def create_tts(provider: str, api_key: str):
    if provider == "openai":
        from pipecat.services.openai.tts import OpenAITTSService
        return OpenAITTSService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google.tts import GoogleTTSService
        return GoogleTTSService(api_key=api_key)
    else:
        raise ValueError(f"TTS provider không hỗ trợ: {provider}")


# ──────────────────────────────────────────────────────────────
# Tùy chỉnh Processor cho luồng PRO TRANSLATE (Soniox Realtime)
# ──────────────────────────────────────────────────────────────
class SonioxRealtimeTranslationSTT(FrameProcessor):
    def __init__(self, api_key: str, translate_type: str = "one_way", lang_a: str = "en", lang_b: str = "vi", enable_diarization: bool = False, extra_context: dict = None, on_translation=None):
        super().__init__()
        self._api_key = api_key
        self._type = translate_type
        self._lang_a = lang_a
        self._lang_b = lang_b
        self._enable_diarization = enable_diarization
        self._extra_context = extra_context or {}
        self._ws = None
        self._receive_task = None
        
        self._final_user_tokens = []
        self._final_bot_tokens = []
        self._current_speaker = 1 
        self._user_flush_task = None
        self._on_translation = on_translation
        
        self.current_translation_lang = lang_b
        self.current_source_lang = lang_a

    async def _flush_buffers_delayed(self):
        await asyncio.sleep(1.0)
        await self._flush_sentence()

    async def _flush_sentence(self):
        bot_text = "".join(self._final_bot_tokens).strip()
        user_text = "".join(self._final_user_tokens).strip()

        if bot_text or user_text:
            if bot_text:
                if not re.search(r'[.!?\n]$', bot_text):
                    bot_text += "."
                
                logger.info(f"Soniox Translated ({self.current_translation_lang}) -> Piper TTS: {bot_text}")

                if self._on_translation:
                    speaker_label = str(self._current_speaker) if self._enable_diarization else "1"
                    await self._on_translation(
                        bot_text,
                        speaker_label,
                        user_text,
                        True,
                        self.current_translation_lang,
                        self.current_source_lang,
                    )
                
                await self.push_frame(LLMFullResponseStartFrame())
                
                # Nhúng mã ngôn ngữ vào metadata để Lớp lọc (LanguageFilter) nhận diện
                text_frame = TextFrame(bot_text)
                text_frame.metadata = {
                    "target_lang": self.current_translation_lang,
                    "source_lang": self.current_source_lang,
                }
                await self.push_frame(text_frame)
                
                await self.push_frame(LLMFullResponseEndFrame())

        self._final_bot_tokens = []
        self._final_user_tokens = []

    async def _receive_messages(self):
        try:
            async for message in self._ws:
                res = json.loads(message)
                if res.get("error_code"):
                    logger.error(f"Soniox Error: {res['error_code']} - {res['error_message']}")
                    await self.push_frame(ErrorFrame(error=res['error_message']))
                    break

                tokens = res.get("tokens", [])
                if not tokens:
                    continue

                has_new_final = False

                for token in tokens:
                    if not token.get("is_final"):
                        continue 

                    status = token.get("translation_status", "")
                    text = token.get("text", "")
                    speaker_id = token.get("speaker", self._current_speaker)
                    token_lang = token.get("language", "")
                    source_lang = token.get("source_language", "")

                    if not text or text.strip().lower() == "<end>":
                        continue

                    self._current_speaker = speaker_id

                    if status == "translation":
                        # Soniox translation token: language = translated language,
                        # source_language = original spoken language.
                        if token_lang:
                            self.current_translation_lang = token_lang
                        if source_lang:
                            self.current_source_lang = source_lang
                        self._final_bot_tokens.append(text)
                        has_new_final = True
                    else:
                        # Original/none token: language = spoken language. For two-way
                        # translation, infer the translation language from the opposite side.
                        if token_lang:
                            self.current_source_lang = token_lang
                            if self._type == "two_way":
                                if token_lang == self._lang_a:
                                    self.current_translation_lang = self._lang_b
                                elif token_lang == self._lang_b:
                                    self.current_translation_lang = self._lang_a
                            else:
                                self.current_translation_lang = self._lang_b
                        self._final_user_tokens.append(text)
                        has_new_final = True

                if has_new_final and self._final_bot_tokens:
                    last_bot_token = self._final_bot_tokens[-1]
                    if re.search(r'[.!?\n]$', last_bot_token.strip()):
                        await self._flush_sentence()
                        if self._user_flush_task:
                            self._user_flush_task.cancel()
                            self._user_flush_task = None
                        continue 

                if has_new_final:
                    if self._user_flush_task:
                        self._user_flush_task.cancel()
                    self._user_flush_task = asyncio.create_task(self._flush_buffers_delayed())

        except websockets.exceptions.ConnectionClosed:
            logger.info("Kết nối Soniox Websocket đã đóng.")
            await self._flush_sentence()
        except Exception as e:
            logger.error(f"Lỗi nhận dữ liệu từ Soniox: {e}")

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            trans_cfg = {
                "type": self._type,
                "target_language": self._lang_b
            } if self._type == "one_way" else {
                "type": "two_way",
                "language_a": self._lang_a,
                "language_b": self._lang_b
            }

            config_stt = {
                "api_key": self._api_key,
                "model": "stt-rt-v4",
                "audio_format": "pcm_s16le",
                "sample_rate": 16000,
                "num_channels": 1,
                "enable_endpoint_detection": True,
                "language_hints": [self._lang_a, self._lang_b] if self._lang_a and self._lang_b else ["en", "vi"],
                "enable_language_identification": True if self._type == "two_way" else False,
                "enable_speaker_diarization": self._enable_diarization,
                "translation": trans_cfg
            }

            if self._extra_context:
                config_stt["context"] = self._extra_context

            self._ws = await websockets.connect("wss://stt-rt.soniox.com/transcribe-websocket")
            await self._ws.send(json.dumps(config_stt))
            self._receive_task = asyncio.create_task(self._receive_messages())
            
            await self.push_frame(frame, direction)

        elif isinstance(frame, AudioRawFrame):
            if self._ws:
                try:
                    await self._ws.send(frame.audio)
                except Exception as e:
                    logger.error(f"Soniox: Error sending audio: {e}")
            pass 

        elif isinstance(frame, EndFrame) or isinstance(frame, CancelFrame):
            if self._ws:
                try:
                    await self._ws.send("")
                    await self._ws.close()
                except Exception:
                    pass
            if self._receive_task:
                self._receive_task.cancel()
            await self.push_frame(frame, direction)

        else:
            await self.push_frame(frame, direction)


# ──────────────────────────────────────────────────────────────
# Lớp Lọc TextFrame theo Ngôn Ngữ
# ──────────────────────────────────────────────────────────────
class LanguageFilter(FrameProcessor):
    """
    Chỉ cho phép các Frame có metadata 'target_lang' khớp với ngôn ngữ được chỉ định đi qua.
    System frames (Start/End/Cancel) luôn được phép đi qua.
    """
    def __init__(self, target_lang: str):
        super().__init__()
        self._target_lang = target_lang

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        
        # System frames luôn đi qua
        if isinstance(frame, (StartFrame, EndFrame, CancelFrame, LLMFullResponseStartFrame, LLMFullResponseEndFrame)):
            await self.push_frame(frame, direction)
            return

        # Chỉ chặn TextFrame nếu không đúng ngôn ngữ
        if isinstance(frame, TextFrame):
            frame_lang = frame.metadata.get("target_lang")
            if frame_lang == self._target_lang:
                await self.push_frame(frame, direction)
        else:
            await self.push_frame(frame, direction)


# ──────────────────────────────────────────────────────────────
# Main Session
# ──────────────────────────────────────────────────────────────
async def start_pipecat_session(config: dict, sdp_offer: str):
    webrtc_connection = SmallWebRTCConnection(ice_servers=ICE_SERVERS)

    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(audio_in_enabled=True, audio_out_enabled=True),
    )

    app_mode = config.get("mode", "gemini_live")

    if app_mode == "gemini_live":
        from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService
        api_key = config.get("google_api_key")
        raw_model = config.get("model", "gemini-2.0-flash-live-001")
        model_name = f"models/{raw_model}" if not raw_model.startswith("models/") else raw_model

        llm = GeminiLiveLLMService(
            api_key=api_key,
            settings=GeminiLiveLLMService.Settings(
                model=model_name,
                system_instruction=config.get("prompt", "Bạn là một trợ lý AI."),
                voice=config.get("voice", "Aoede"),
            ),
        )

        context = LLMContext([{"role": "user", "content": "Hãy chào tôi một câu."}])
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(context)

        processors = [transport.input(), user_aggregator, llm, transport.output(), assistant_aggregator]

    elif app_mode == "pro_translate":
        ssl._create_default_https_context = ssl._create_unverified_context
        try:
            from pipecat.services.piper.tts import PiperTTSService
        except ImportError:
            raise Exception("Chưa cài đặt piper-tts! pip install \"pipecat-ai[piper]\"")

        stt_cfg = config.get("stt") or {}
        tts_cfg = config.get("tts") or {}

        soniox_api_key = stt_cfg.get("api_key", "")
        piper_voice = tts_cfg.get("model", "vi_VN-vivos-x_low")
        piper_voice_b = tts_cfg.get("model_b", "en_US-lessac-medium")

        target_lang = config.get("target_language", "vi")
        source_lang = config.get("source_language", "en")
        trans_type = config.get("translation_type", "two_way")
        soniox_context = config.get("soniox_context", None)
        diarize = stt_cfg.get("diarize", False)
        routing_cfg = config.get("routing") or {}
        process_logic = routing_cfg.get("process_logic", "speaker")

        async def _send_transcript(
            text: str,
            speaker: str,
            source_text: str,
            is_final: bool,
            translation_language: str = "",
            source_language: str = "",
        ):
            try:
                speaker_num = re.sub(r"[^0-9]", "", str(speaker))
                if (
                    trans_type == "two_way"
                    and process_logic == "translate"
                    and translation_language
                ):
                    audio_target = "speaker2" if translation_language == source_lang else "speaker1"
                else:
                    audio_target = "speaker1" if speaker_num in ("", "1") else "speaker2"
                msg = {
                    "type": "pro_translate",
                    "data": {
                        "speaker": speaker,
                        "source": source_text,
                        "translation": text,
                        "is_final": is_final,
                        "audio_target": audio_target,
                        "translation_language": translation_language,
                        "source_language": source_language,
                        "process_logic": process_logic,
                    }
                }
                webrtc_connection.send_app_message(msg)
            except Exception as e:
                logger.error(f"Data channel send error: {e}")

        stt_translate = SonioxRealtimeTranslationSTT(
            api_key=soniox_api_key,
            translate_type=trans_type,
            lang_a=source_lang,
            lang_b=target_lang,
            enable_diarization=diarize,
            extra_context=soniox_context,
            on_translation=_send_transcript
        )

        tts_vi = PiperTTSService(settings=PiperTTSService.Settings(voice=piper_voice))
        filter_vi = LanguageFilter(target_lang)
        
        # Nếu là TWO_WAY, chúng ta tạo một luồng song song (ParallelPipeline)
        if trans_type == "two_way" and piper_voice_b:
            tts_en = PiperTTSService(settings=PiperTTSService.Settings(voice=piper_voice_b))
            filter_en = LanguageFilter(source_lang)
            
            # Chia frame sang 2 nhánh: nhánh lọc Tiếng Việt và nhánh lọc Tiếng Anh
            tts_pipeline = ParallelPipeline(
                [filter_vi, tts_vi],
                [filter_en, tts_en]
            )
            logger.info(f"Pro Translate TWO_WAY: {source_lang}→{target_lang} [{piper_voice}] | {target_lang}→{source_lang} [{piper_voice_b}]")
        else:
            tts_pipeline = Pipeline([filter_vi, tts_vi])
            logger.info(f"Pro Translate ONE_WAY: {source_lang}→{target_lang} [{piper_voice}]")

        processors = [
            transport.input(),
            stt_translate,
            tts_pipeline,
            transport.output()
        ]
    else:
        raise ValueError(f"Mode không hỗ trợ: {app_mode}")

    pipeline = Pipeline(processors)
    task = PipelineTask(pipeline, params=PipelineParams(allow_interruptions=True, enable_metrics=True))

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        if app_mode == "gemini_live":
            await task.queue_frames([LLMRunFrame()])
        else:
            logger.info("Client connected (Pro Translate).")

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        await task.cancel()

    runner = PipelineRunner()
    asyncio.create_task(runner.run(task))
    await asyncio.sleep(0.5)

    await webrtc_connection.initialize(sdp=sdp_offer, type="offer")
    answer = webrtc_connection.get_answer()
    
    filtered_sdp = filter_sdp_relay_only(answer.get("sdp", ""))
    answer["sdp"] = filtered_sdp
    pcs_map[answer["pc_id"]] = webrtc_connection

    @webrtc_connection.event_handler("closed")
    async def handle_closed(conn: SmallWebRTCConnection):
        pcs_map.pop(conn.pc_id, None)
        await task.cancel()

    return answer


@app.post("/connect")
async def connect_endpoint(request: Request):
    data = await request.json()
    try:
        answer = await start_pipecat_session(data.get("config", {}), data.get("sdp"))
        return {"sdp": answer["sdp"], "type": answer["type"]}
    except Exception as e:
        logger.error(f"Lỗi khởi tạo session: {e}")
        return {"error": str(e)}, 500

if __name__ == "__main__":
    uvicorn.run("ws_server:app", host="0.0.0.0", port=3000, reload=False, log_level="info")
