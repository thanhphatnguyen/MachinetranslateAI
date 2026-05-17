import asyncio
import json
import logging
import re
import ssl
import urllib.request
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import websockets

# Pipecat core
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.frames.frames import LLMRunFrame, Frame, AudioRawFrame, TextFrame, StartFrame, EndFrame, CancelFrame, ErrorFrame
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
#
# aiortc 1.14.0 chưa support iceTransportPolicy trong RTCConfiguration
# (issue #1397). Giải pháp: patch gather_candidates của aioice để
# sau khi gather xong, chỉ giữ lại candidates loại "relay".
# ──────────────────────────────────────────────────────────────
import aioice.ice as _aioice_ice

_original_gather = _aioice_ice.Connection.gather_candidates

async def _relay_only_gather(self):
    """Chạy gather gốc rồi filter chỉ giữ relay candidates."""
    await _original_gather(self)
    before = len(self._local_candidates)
    self._local_candidates = [
        c for c in self._local_candidates if c.type == "relay"
    ]
    after = len(self._local_candidates)
    logger.info(
        f"ICE relay-only patch: {before} candidates → giữ {after} relay, "
        f"bỏ {before - after} host/srflx"
    )

_aioice_ice.Connection.gather_candidates = _relay_only_gather
logger.info("Monkey-patch aioice gather_candidates: relay-only ICE applied")
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


# ──────────────────────────────────────────────────────────────
# SDP Filter: Chỉ giữ relay candidates, bỏ host/srflx
# Giải quyết vấn đề ICE timeout do check local candidates vô ích
# ──────────────────────────────────────────────────────────────
def filter_sdp_relay_only(sdp: str) -> str:
    """
    Lọc SDP chỉ giữ lại relay candidates (từ TURN server).
    Loại bỏ host (local IP) và srflx (STUN) vì UDP bị chặn.
    """
    lines = sdp.split("\r\n") if "\r\n" in sdp else sdp.split("\n")
    newline = "\r\n" if "\r\n" in sdp else "\n"
    
    filtered = []
    removed = []
    
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
                    removed.append(f"{candidate_type}: {line}")
                    # Bỏ qua host và srflx
            else:
                filtered.append(line)
        else:
            filtered.append(line)
    
    if removed:
        logger.info(f"SDP filter: bỏ {len(removed)} non-relay candidates:")
        for r in removed:
            logger.info(f"  - {r}")
    
    relay_count = sum(1 for l in filtered if "typ relay" in l)
    logger.info(f"SDP filter: giữ lại {relay_count} relay candidates")
    
    return newline.join(filtered)


# ──────────────────────────────────────────────────────────────
# Factory Functions
# ──────────────────────────────────────────────────────────────

def create_stt(provider: str, api_key: str, diarize: bool = False, target_language: str = None, context: dict = None):
    if provider == "deepgram":
        from pipecat.services.deepgram.stt import DeepgramSTTService
        return DeepgramSTTService(api_key=api_key, diarize=diarize)
    elif provider == "openai":
        from pipecat.services.openai.stt import OpenAISTTService
        return OpenAISTTService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google.stt import GoogleSTTService
        return GoogleSTTService(api_key=api_key)
    elif provider == "assemblyai":
        from pipecat.services.assemblyai.stt import AssemblyAISTTService
        return AssemblyAISTTService(api_key=api_key, speaker_labels=diarize)
    elif provider == "soniox":
        from pipecat.services.soniox.stt import SonioxSTTService
        kwargs = {"api_key": api_key, "enable_speaker_diarization": diarize}
        if target_language:
            kwargs["target_language"] = target_language
        if context:
            kwargs["context"] = context
        return SonioxSTTService(**kwargs)
    elif provider == "groq":
        from pipecat.services.groq.stt import GroqSTTService
        return GroqSTTService(api_key=api_key)
    elif provider == "mistral":
        from pipecat.services.mistral.stt import MistralSTTService
        return MistralSTTService(api_key=api_key)
    elif provider == "whisper":
        from pipecat.services.whisper.stt import WhisperSTTService
        return WhisperSTTService(api_key=api_key)
    else:
        raise ValueError(f"STT provider không hỗ trợ: {provider}")


def create_llm(provider: str, api_key: str, model: str):
    if provider == "openai":
        from pipecat.services.openai.llm import OpenAILLMService
        return OpenAILLMService(api_key=api_key, model=model)
    elif provider == "anthropic":
        from pipecat.services.anthropic.llm import AnthropicLLMService
        return AnthropicLLMService(api_key=api_key, model=model)
    elif provider == "google":
        from pipecat.services.google.llm import GoogleLLMService
        return GoogleLLMService(api_key=api_key, model=model)
    elif provider == "groq":
        from pipecat.services.groq.llm import GroqLLMService
        return GroqLLMService(api_key=api_key, model=model)
    elif provider == "mistral":
        from pipecat.services.mistral.llm import MistralLLMService
        return MistralLLMService(api_key=api_key, model=model)
    else:
        raise ValueError(f"LLM provider không hỗ trợ: {provider}")


def create_tts(provider: str, api_key: str):
    if provider == "deepgram":
        from pipecat.services.deepgram.tts import DeepgramTTSService
        return DeepgramTTSService(api_key=api_key)
    elif provider == "openai":
        from pipecat.services.openai.tts import OpenAITTSService
        return OpenAITTSService(api_key=api_key)
    elif provider == "google":
        from pipecat.services.google.tts import GoogleTTSService
        return GoogleTTSService(api_key=api_key)
    elif provider == "elevenlabs":
        from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
        return ElevenLabsTTSService(api_key=api_key)
    elif provider == "cartesia":
        from pipecat.services.cartesia.tts import CartesiaTTSService
        return CartesiaTTSService(api_key=api_key)
    elif provider == "soniox":
        from pipecat.services.soniox.tts import SonioxTTSService
        return SonioxTTSService(api_key=api_key)
    elif provider == "groq":
        from pipecat.services.groq.tts import GroqTTSService
        return GroqTTSService(api_key=api_key)
    elif provider == "mistral":
        from pipecat.services.mistral.tts import MistralTTSService
        return MistralTTSService(api_key=api_key)
    else:
        raise ValueError(f"TTS provider không hỗ trợ: {provider}")


# ──────────────────────────────────────────────────────────────
# Tùy chỉnh Processor cho luồng PRO TRANSLATE (Soniox Realtime)
# ──────────────────────────────────────────────────────────────
class SonioxRealtimeTranslationSTT(FrameProcessor):
    """
    Bắt khung âm thanh từ WebRTC, đẩy lên Websocket của Soniox.
    Hứng các token dịch thuật, gom lại thành câu rồi đẩy vào TextFrame cho TTS.
    """
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
        self._translation_buffer = []
        self._user_buffer = []
        self._user_flush_task = None
        self._on_translation = on_translation
        self._last_user_was_final = True
        self._last_translation_was_final = True
        self._current_speaker = ""  # Speaker label từ Soniox diarization

    async def _flush_user_buffer_delayed(self):
        """Timer chỉ clear buffer im lặng, KHÔNG gửi user text nếu không có translation."""
        await asyncio.sleep(1.5)
        if self._user_buffer:
            self._user_buffer = []
            self._last_user_was_final = True

    async def _receive_messages(self):
        try:
            async for message in self._ws:
                res = json.loads(message)
                if res.get("error_code"):
                    logger.error(f"Soniox Error: {res['error_code']} - {res['error_message']}")
                    await self.push_frame(ErrorFrame(error=res['error_message']))
                    break

                tokens = res.get("tokens", [])
                if tokens:
                    logger.debug(f"Soniox: Received {len(tokens)} tokens")

                for token in tokens:
                    status = token.get("translation_status", "")
                    text = token.get("text", "")
                    is_final = token.get("is_final", False)

                    # ── FIX 1: Bỏ qua <end> token từ Soniox endpoint detection ──
                    if text.strip().lower() == "<end>":
                        continue

                    if not text:
                        continue

                    # ── FIX: Source speech tokens (user transcript) ──
                    # Dùng _last_user_was_final flag để xác định REPLACE hay APPEND:
                    # - non-final → non-final: REPLACE (token mở rộng, VD: H→Ho→Hom)
                    # - non-final → final: REPLACE (bản hoàn chỉnh thay thế bản nháp)
                    # - final → final: APPEND (token mới, câu mới)
                    # - final → non-final: APPEND (token mới bắt đầu mở rộng)
                    if status != "translation":
                        # Capture speaker label từ Soniox diarization
                        token_speaker = token.get("speaker", "")
                        if token_speaker:
                            self._current_speaker = token_speaker
                        if is_final:
                            if not self._last_user_was_final and self._user_buffer:
                                self._user_buffer[-1] = text  # REPLACE non-final → final
                            else:
                                self._user_buffer.append(text)  # APPEND final sau final
                            self._last_user_was_final = True
                        else:
                            if not self._last_user_was_final and self._user_buffer:
                                self._user_buffer[-1] = text  # REPLACE non-final → non-final
                            else:
                                self._user_buffer.append(text)  # APPEND non-final sau final
                            self._last_user_was_final = False
                        if self._user_flush_task:
                            self._user_flush_task.cancel()
                        self._user_flush_task = asyncio.create_task(self._flush_user_buffer_delayed())

                    # ── FIX: Translation tokens (bot transcript) ──
                    if status == "translation":
                        if is_final:
                            if not self._last_translation_was_final and self._translation_buffer:
                                self._translation_buffer[-1] = text  # REPLACE non-final → final
                            else:
                                self._translation_buffer.append(text)  # APPEND final sau final
                            self._last_translation_was_final = True
                        else:
                            if not self._last_translation_was_final and self._translation_buffer:
                                self._translation_buffer[-1] = text  # REPLACE non-final → non-final
                            else:
                                self._translation_buffer.append(text)  # APPEND non-final sau final
                            self._last_translation_was_final = False

                        # Flush khi gặp dấu câu cuối câu
                        if is_final and re.search(r'[.!?\n]$', text.strip()):
                            complete_text = "".join(self._translation_buffer).strip()
                            if complete_text:
                                if not re.search(r'[.!?\n]$', complete_text):
                                    complete_text += "."
                                # Get paired source text
                                source_text = "".join(self._user_buffer).strip()
                                self._user_buffer = []
                                logger.info(f"Soniox Translated -> Piper TTS: {complete_text}")
                                
                                # ── FIX: Báo hiệu cho TTS biết bắt đầu và kết thúc một câu nói ──
                                from pipecat.frames.frames import LLMFullResponseStartFrame, LLMFullResponseEndFrame
                                
                                await self.push_frame(LLMFullResponseStartFrame())
                                await self.push_frame(TextFrame(complete_text))
                                await self.push_frame(LLMFullResponseEndFrame())
                                # ─────────────────────────────────────────────────────────────
                                
                                if self._on_translation:
                                    speaker_label = self._current_speaker or "Speaker"
                                    await self._on_translation(complete_text, speaker_label, source_text)
                            self._translation_buffer = []

        except websockets.exceptions.ConnectionClosed:
            logger.info("Kết nối Soniox Websocket đã đóng.")
            # Flush remaining buffers
            if self._translation_buffer:
                complete_text = "".join(self._translation_buffer).strip()
                if complete_text:
                    source_text = "".join(self._user_buffer).strip()
                    self._user_buffer = []
                    logger.info(f"Soniox Translated (final) -> Piper TTS: {complete_text}")
                    from pipecat.frames.frames import LLMFullResponseStartFrame, LLMFullResponseEndFrame
                    await self.push_frame(LLMFullResponseStartFrame())
                    await self.push_frame(TextFrame(complete_text))
                    await self.push_frame(LLMFullResponseEndFrame())
                    if self._on_translation:
                        speaker_label = self._current_speaker or "Speaker"
                        await self._on_translation(complete_text, speaker_label, source_text)
                self._translation_buffer = []
            if self._user_buffer:
                complete_user = "".join(self._user_buffer).strip()
                if complete_user and self._on_translation:
                    await self._on_translation(complete_user, "user")
                self._user_buffer = []
        except Exception as e:
            logger.error(f"Lỗi nhận dữ liệu từ Soniox: {e}")

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        # Call parent to handle StartFrame lifecycle (__started = True)
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            # Thiết lập config translation tùy theo cấu hình Flutter gửi lên
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

            logger.info(f"Soniox: Connecting to WebSocket...")
            self._ws = await websockets.connect("wss://stt-rt.soniox.com/transcribe-websocket")
            logger.info(f"Soniox: Connected! Sending config...")
            await self._ws.send(json.dumps(config_stt))
            logger.info(f"Soniox: Config sent, starting receive task...")
            self._receive_task = asyncio.create_task(self._receive_messages())
            
            # Cho phép StartFrame đi qua
            await self.push_frame(frame, direction)

        elif isinstance(frame, AudioRawFrame):
            if self._ws:
                try:
                    await self._ws.send(frame.audio)
                except Exception as e:
                    logger.error(f"Soniox: Error sending audio: {e}")
            
            # ── FIX QUAN TRỌNG: LÀM "CHÌM" KHUNG ÂM THANH GỐC ──
            # KHÔNG gọi await self.push_frame(frame, direction) ở đây nữa!
            # Điều này ngăn không cho tiếng mic của bạn lọt thẳng vào TTS.
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
                
            # Cho phép End/Cancel Frame đi qua
            await self.push_frame(frame, direction)

        else:
            # ── CHUYỂN TIẾP CÁC FRAME KHÁC ──
            # (Rất quan trọng để chuyển các StartInterruptionFrame, v.v.)
            await self.push_frame(frame, direction)


# ──────────────────────────────────────────────────────────────
# Main Session
# ──────────────────────────────────────────────────────────────

async def start_pipecat_session(config: dict, sdp_offer: str):
    """Khởi tạo và chạy pipeline Pipecat WebRTC"""

    webrtc_connection = SmallWebRTCConnection(ice_servers=ICE_SERVERS)

    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    )
    logger.info("Transport WebRTC đã được tạo (Audio In/Out: Bật)")

    app_mode = config.get("mode", "gemini_live")

    if app_mode == "gemini_live":
        try:
            from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService
        except ImportError as e:
            logger.error(f"Chưa cài đặt đúng gói Google! Lỗi: {e}")
            raise

        api_key = config.get("google_api_key")
        raw_model = config.get("model", "gemini-2.0-flash-live-001")
        model_name = f"models/{raw_model}" if not raw_model.startswith("models/") else raw_model

        llm = GeminiLiveLLMService(
            api_key=api_key,
            settings=GeminiLiveLLMService.Settings(
                model=model_name,
                system_instruction=config.get(
                    "prompt",
                    "Bạn là một trợ lý AI giao tiếp bằng giọng nói. Hãy trả lời ngắn gọn, tự nhiên bằng tiếng Việt.",
                ),
                voice=config.get("voice", "Aoede"),
            ),
        )

        context = LLMContext([{
            "role": "user",
            "content": "Hãy chào tôi một câu ngắn gọn bằng tiếng Việt để bắt đầu cuộc trò chuyện.",
        }])
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(context)

        processors = [
            transport.input(),
            user_aggregator,
            llm,
            transport.output(),
            assistant_aggregator,
        ]
        logger.info(f"Đã nạp não Gemini Live (Model: {model_name})")

    elif app_mode == "stt_llm_tts":
        stt_cfg = config.get("stt") or {}
        llm_cfg = config.get("llm") or {}
        tts_cfg = config.get("tts") or {}

        if not stt_cfg.get("provider") or stt_cfg["provider"] == "none":
            raise ValueError("STT provider là bắt buộc cho chế độ stt_llm_tts")
        if not llm_cfg.get("provider") or llm_cfg["provider"] == "none":
            raise ValueError("LLM provider là bắt buộc cho chế độ stt_llm_tts")
        if not tts_cfg.get("provider") or tts_cfg["provider"] == "none":
            raise ValueError("TTS provider là bắt buộc cho chế độ stt_llm_tts")

        stt = create_stt(stt_cfg["provider"], stt_cfg["api_key"])
        llm = create_llm(llm_cfg["provider"], llm_cfg["api_key"], llm_cfg["model"])
        tts = create_tts(tts_cfg["provider"], tts_cfg["api_key"])

        from pipecat.processors.aggregators.llm_response_universal import LLMUserAggregatorParams
        from pipecat.audio.vad.silero import SileroVADAnalyzer

        context = LLMContext([{
            "role": "system",
            "content": config.get(
                "prompt",
                "Bạn là một trợ lý dịch thuật. Dịch những gì người dùng nói sang tiếng Việt. Trả lời ngắn gọn.",
            ),
        }])
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
            context,
            user_params=LLMUserAggregatorParams(vad_analyzer=SileroVADAnalyzer()),
        )

        processors = [
            transport.input(),
            stt,
            user_aggregator,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
        logger.info(
            f"Pipeline STT+LLM+TTS (STT={stt_cfg['provider']}, "
            f"LLM={llm_cfg['provider']}/{llm_cfg['model']}, "
            f"TTS={tts_cfg['provider']})"
        )

    elif app_mode == "pro_translate":
        # Fix SSL certificate verification for model download
        ssl._create_default_https_context = ssl._create_unverified_context

        try:
            from pipecat.services.piper.tts import PiperTTSService
        except ImportError:
            logger.error("Chưa cài đặt piper-tts! Vui lòng chạy: pip install piper-tts")
            raise

        stt_cfg = config.get("stt") or {}
        tts_cfg = config.get("tts") or {}

        soniox_api_key = stt_cfg.get("api_key", "")
        piper_voice = tts_cfg.get("model", "vi_VN-vivos-x_low")

        target_lang = config.get("target_language", "vi")
        source_lang = config.get("source_language", "en")
        trans_type = config.get("translation_type", "two_way")
        soniox_context = config.get("soniox_context", None)
        diarize = stt_cfg.get("diarize", False)

        if not soniox_api_key:
            raise ValueError("STT API Key (Soniox) là bắt buộc cho chế độ pro_translate")

        stt_translate = SonioxRealtimeTranslationSTT(
            api_key=soniox_api_key,
            translate_type=trans_type,
            lang_a=source_lang,
            lang_b=target_lang,
            enable_diarization=diarize,
            extra_context=soniox_context,
            on_translation=lambda text, speaker, src='': _send_transcript(text, speaker, src)
        )

        tts = PiperTTSService(settings=PiperTTSService.Settings(voice=piper_voice))

        processors = [
            transport.input(),
            stt_translate,
            tts,
            transport.output()
        ]
        logger.info(f"Đã nạp luồng Pro Translate (Soniox STT [{trans_type}: {source_lang}-{target_lang}] -> Piper TTS [{piper_voice}])")
    else:
        raise ValueError(f"Mode không hỗ trợ: {app_mode}")

    # Data channel for transcripts
    async def _send_transcript(text: str, speaker: str = "bot", source_text: str = ""):
        try:
            msg = {
                "type": "pro_translate",
                "data": {
                    "speaker": speaker,
                    "source": source_text,
                    "translation": text
                }
            }
            webrtc_connection.send_app_message(msg)
        except Exception as e:
            logger.error(f"Data channel send error: {e}")

    pipeline = Pipeline(processors)
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            allow_interruptions=True,
            enable_metrics=True,
        ),
    )

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        if app_mode == "pro_translate":
            logger.info("Client connected (Pro Translate).")
        else:
            logger.info("Client connected -> Ép AI cất tiếng chào!")
            await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("Client disconnected -> Tắt task AI.")
        await task.cancel()

    runner = PipelineRunner()
    asyncio.create_task(runner.run(task))

    await asyncio.sleep(0.5)

    logger.info("Đang đàm phán WebRTC (Signaling) với điện thoại...")
    await webrtc_connection.initialize(sdp=sdp_offer, type="offer")

    answer = webrtc_connection.get_answer()
    if not answer:
        raise Exception("Không thể tạo được SDP Answer từ server.")

    # ── KEY FIX: Lọc SDP chỉ giữ relay candidates ──────────────
    original_sdp = answer.get("sdp", "")
    filtered_sdp = filter_sdp_relay_only(original_sdp)
    answer["sdp"] = filtered_sdp
    # ────────────────────────────────────────────────────────────

    relay_candidates = re.findall(r'a=candidate:.+relay.+', filtered_sdp)
    logger.info(f"Server relay candidates ({len(relay_candidates)}):")
    for c in relay_candidates:
        logger.info(f"  {c}")

    pcs_map[answer["pc_id"]] = webrtc_connection

    @webrtc_connection.event_handler("closed")
    async def handle_closed(conn: SmallWebRTCConnection):
        logger.info(f"WebRTC Connection closed: {conn.pc_id}")
        pcs_map.pop(conn.pc_id, None)
        await task.cancel()

    return answer


@app.post("/connect")
async def connect_endpoint(request: Request):
    data = await request.json()
    config = data.get("config", {})
    offer = data.get("sdp")

    if not offer:
        return {"error": "Missing SDP offer"}, 400

    try:
        logger.info(f"Khởi tạo session {config.get('mode', 'gemini_live')} mới...")
        answer = await start_pipecat_session(config, offer)
        return {
            "sdp": answer["sdp"],
            "type": answer["type"],
        }
    except Exception as e:
        logger.error(f"Lỗi khởi tạo session: {e}")
        return {"error": str(e)}, 500


@app.get("/")
async def root():
    return {"status": "ok", "message": "Pipecat WebRTC Server Active"}


@app.get("/health")
async def health():
    return {"status": "healthy"}


if __name__ == "__main__":
    uvicorn.run(
        "ws_server:app",
        host="0.0.0.0",
        port=3000,
        reload=False,
        log_level="info",
    )