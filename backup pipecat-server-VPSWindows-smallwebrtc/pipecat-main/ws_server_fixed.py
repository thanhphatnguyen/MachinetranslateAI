import asyncio
import json
import logging
import re
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import websockets

# Pipecat core
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.frames.frames import (
    LLMRunFrame, AudioRawFrame, TextFrame, StartFrame, 
    EndFrame, CancelFrame, ErrorFrame
)

# Pipecat WebRTC Transport
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
# SDP Filter & Factory Functions
# ──────────────────────────────────────────────────────────────
def filter_sdp_relay_only(sdp: str) -> str:
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
            else:
                filtered.append(line)
        else:
            filtered.append(line)
    
    if removed:
        logger.info(f"SDP filter: bỏ {len(removed)} non-relay candidates.")
    
    relay_count = sum(1 for l in filtered if "typ relay" in l)
    logger.info(f"SDP filter: giữ lại {relay_count} relay candidates")
    
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
    elif provider == "assemblyai":
        from pipecat.services.assemblyai.stt import AssemblyAISTTService
        return AssemblyAISTTService(api_key=api_key, speaker_labels=diarize)
    elif provider == "soniox":
        from pipecat.services.soniox.stt import SonioxSTTService
        return SonioxSTTService(api_key=api_key, enable_speaker_diarization=diarize)
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
    def __init__(self, api_key: str, translate_type: str = "one_way", lang_a: str = "en", lang_b: str = "vi",enable_diarization: bool = False, extra_context: dict = None):
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

    async def _receive_messages(self):
        try:
            async for message in self._ws:
                res = json.loads(message)
                if res.get("error_code"):
                    logger.error(f"Soniox Error: {res['error_code']} - {res['error_message']}")
                    await self.push_frame(ErrorFrame(error=res['error_message']))
                    break
                
                # Bóc tách và bắt ngay các Token
                for token in res.get("tokens", []):
                    # Chúng ta chỉ quan tâm phần dịch
                    if token.get("translation_status") == "translation":
                        text = token.get("text", "")
                        is_final = token.get("is_final", False)

                        if text:
                            # Tích lũy vào buffer
                            self._translation_buffer.append(text)
                            
                            # Nếu chốt câu, đẩy nguyên 1 cục cho TTS
                            if is_final:
                                complete_text = "".join(self._translation_buffer).strip()
                                # Thêm dấu câu để Piper TTS ngắt nghỉ chuẩn
                                if complete_text and not re.search(r'[.!?\n]$', complete_text):
                                    complete_text += "."
                                
                                logger.info(f"Soniox Translated -> Piper TTS: {complete_text}")
                                await self.push_frame(TextFrame(complete_text))
                                # Xóa bộ đệm
                                self._translation_buffer = []
                            
        except websockets.exceptions.ConnectionClosed:
            logger.info("Kết nối Soniox Websocket đã đóng.")
        except Exception as e:
            logger.error(f"Lỗi nhận dữ liệu từ Soniox: {e}")

    async def process_frame(self, frame: Frame, direction: FrameDirection):
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
            
            # Khởi tạo config với các tính năng xịn xò
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

            # Nạp thêm context (từ vựng) nếu có
            if self._extra_context:
                config_stt["context"] = self._extra_context

            self._ws = await websockets.connect("wss://stt-rt.soniox.com/transcribe-websocket")
            await self._ws.send(json.dumps(config_stt))
            self._receive_task = asyncio.create_task(self._receive_messages())
            await self.push_frame(frame, direction)

        elif isinstance(frame, AudioRawFrame):
            # Bơm âm thanh thô thẳng lên Soniox
            if self._ws and self._ws.open:
                await self._ws.send(frame.audio)
            
        elif isinstance(frame, EndFrame) or isinstance(frame, CancelFrame):
            if self._ws and self._ws.open:
                await self._ws.send("") 
                await self._ws.close()
            if self._receive_task:
                self._receive_task.cancel()
            await self.push_frame(frame, direction)
        else:
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

    # ==========================================
    # CHẾ ĐỘ 1: GEMINI LIVE 
    # ==========================================
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

    # ==========================================
    # CHẾ ĐỘ 2: STT -> LLM -> TTS
    # ==========================================
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
        
    # ==========================================
    # CHẾ ĐỘ 3: PRO TRANSLATE (Soniox -> Piper)
    # ==========================================
    elif app_mode == "pro_translate":
        try:
            from pipecat.services.piper.tts import PiperTTSService
        except ImportError:
            logger.error("Chưa cài đặt piper-tts! Vui lòng chạy: pip install piper-tts")
            raise
            
        stt_cfg = config.get("stt") or {}
        tts_cfg = config.get("tts") or {}
        
        soniox_api_key = stt_cfg.get("api_key", "")
        piper_voice = tts_cfg.get("model", "vi_VN-vivos-x_low") 
        
        # Thiết lập ngôn ngữ và chế độ (lấy từ cấu hình hoặc mặc định)
        target_lang = config.get("target_language", "vi")
        source_lang = config.get("source_language", "en")
        trans_type = config.get("translation_type", "two_way") # Cho phép dịch 2 chiều mặc định
        soniox_context = config.get("soniox_context", None) # Để nạp từ vựng chuyên ngành

        # Lấy tùy chọn diarize từ config STT (Mặc định là False)
        diarize = stt_cfg.get("diarize", False)
        
        # Khởi tạo cầu nối Soniox
        stt_translate = SonioxRealtimeTranslationSTT(
            api_key=soniox_api_key, 
            translate_type=trans_type, 
            lang_a=source_lang,
            lang_b=target_lang,
            enable_diarization=diarize,
            extra_context=soniox_context
        )
        
        # Khởi tạo Piper TTS
        tts = PiperTTSService(voice=piper_voice)

        processors = [
            transport.input(),
            stt_translate,
            tts,
            transport.output()
        ]
        logger.info(f"Đã nạp luồng Pro Translate (Soniox STT [{trans_type}: {source_lang}-{target_lang}] -> Piper TTS [{piper_voice}])")

    else:
        raise ValueError(f"Mode không hỗ trợ: {app_mode}")

    # ==========================================
    # Chạy Pipeline
    # ==========================================
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
        if app_mode == "gemini_live":
            logger.info("Client connected -> Ép AI cất tiếng chào!")
            await task.queue_frames([LLMRunFrame()])
        else:
            logger.info("Client connected.")

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

    # Lọc SDP chỉ giữ relay candidates
    original_sdp = answer.get("sdp", "")
    filtered_sdp = filter_sdp_relay_only(original_sdp)
    answer["sdp"] = filtered_sdp

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