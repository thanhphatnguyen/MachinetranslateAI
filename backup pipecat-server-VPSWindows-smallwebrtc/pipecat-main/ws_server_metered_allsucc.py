import asyncio
import json
import logging
import re
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Pipecat core
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.frames.frames import LLMRunFrame

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

# Chỉ TURN TCP — UDP đã confirm bị chặn hoàn toàn
ICE_SERVERS = [
    IceServer(
        urls="turn:asia.relay.metered.ca:80?transport=tcp",
        username="cc84af1584a60af7a8aae396",
        credential="DYooULJ9XzeVTjwa",
    ),
    IceServer(
        urls="turn:asia.relay.metered.ca:443?transport=tcp",
        username="cc84af1584a60af7a8aae396",
        credential="DYooULJ9XzeVTjwa",
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
    else:
        raise ValueError(f"Mode không hỗ trợ: {app_mode}")

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