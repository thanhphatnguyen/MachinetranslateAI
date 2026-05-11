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
# FastAPI App Setup
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
    IceServer(urls="stun:35.199.170.99:3478"),
    IceServer(
        urls="turn:35.199.170.99:3478",
        username="test",
        credential="test123",
    ),
]


async def start_pipecat_session(config: dict, sdp_offer: str):
    """Khởi tạo và chạy pipeline Pipecat WebRTC cho Speech-to-Speech"""

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
                system_instruction=config.get("prompt", "Bạn là một trợ lý AI giao tiếp bằng giọng nói. Hãy trả lời ngắn gọn, tự nhiên bằng tiếng Việt."),
                voice=config.get("voice", "Aoede"),
            ),
        )

        context = LLMContext(
            [
                {
                    "role": "user",
                    "content": "Hãy chào tôi một câu ngắn gọn bằng tiếng Việt để bắt đầu cuộc trò chuyện.",
                },
            ],
        )
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(context)

        processors = [
            transport.input(),
            user_aggregator,
            llm,
            transport.output(),
            assistant_aggregator
        ]

        logger.info(f"Đã nạp não Gemini Live (Model: {model_name})")
    else:
        raise ValueError("File này hiện đang được tối ưu riêng cho chế độ gemini_live.")

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
    runner_task = asyncio.create_task(runner.run(task))

    await asyncio.sleep(0.5)

    logger.info("Đang đàm phán WebRTC (Signaling) với điện thoại...")
    await webrtc_connection.initialize(sdp=sdp_offer, type="offer")

    answer = webrtc_connection.get_answer()
    if not answer:
        raise Exception("Không thể tạo được SDP Answer từ server.")

    candidates = re.findall(r'a=candidate:.+', answer.get("sdp", ""))
    logger.info(f"Server local candidates ({len(candidates)}):")
    for c in candidates:
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
    """WebRTC signaling endpoint cho Flutter app"""
    data = await request.json()
    config = data.get("config", {})
    offer = data.get("sdp")

    if not offer:
        return {"error": "Missing SDP offer"}, 400

    try:
        logger.info("Khởi tạo session WebRTC mới...")
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
        reload=True,
        log_level="info",
    )
