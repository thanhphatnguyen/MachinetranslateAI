# 📋 GOOGLE CLOUD DEPLOY - PIPECAT SERVER LOG
> **Ngày tạo**: 2026-05-10
> **Trạng thái**: ✅ Server hoạt động - AI nói được - Cần fix user audio recognition

---

## ⚠️ TÌNH TRẠNG HIỆN TẠI

### ✅ Đã hoạt động
- Server chạy trên Google Cloud VM (35.199.170.99:3000)
- WebRTC connection thành công (ICE completed)
- Gemini Live connected
- AI phản hồi âm thanh (Bot started/stopped speaking)

### ❌ Cần fix
- Server không ghi nhận/transcript âm thanh từ user nói qua mic
- Có thể do Gemini Live mode không tự transcript, hoặc cần cấu hình thêm

### Nguyên nhân có thể
1. Gemini Live mode chỉ nhận audio nhưng không trả transcript text
2. Cần thêm STT (Speech-to-Text) service để transcript
3. Hoặc cần cấu hình Gemini để bật transcript output

---

## 1. THÔNG TIN VM

| Thông tin | Giá trị |
|-----------|---------|
| Tên | instance-20260510-044745 |
| Region | asia-southeast1 (Singapore) |
| Machine type | e2-small (2 vCPU, 1GB RAM) |
| OS | Ubuntu 22.04 LTS x86/64 |
| External IP | 35.199.170.99 |
| Internal IP | 10.138.0.2 |

---

## 2. FIREWALL RULES ĐÃ TẠO

| Rule name | Direction | Protocols/Ports | Source IP | Mục đích |
|-----------|-----------|-----------------|-----------|----------|
| allow-tcp-3000 | Ingress | tcp:3000 | 0.0.0.0/0 | Pipecat server |
| allow-udp-3478 | Ingress | udp:3478 | 0.0.0.0/0 | STUN/TURN |
| allow-udp-webrtc | Ingress | udp:49152-65535 | 0.0.0.0/0 | WebRTC media |
| allow-tcp-ssh | Ingress | tcp:22 | 0.0.0.0/0 | SSH |

---

## 3. CÀI ĐẶT TRÊN VM

### 3.1. Cài đặt hệ thống
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv git nano libgl1-mesa-glx
```

### 3.2. Tạo thư mục và virtual environment
```bash
mkdir -p ~/pipecat-server
cd ~/pipecat-server
python3 -m venv venv
source venv/bin/activate
```

### 3.3. Cài Python packages
```bash
# Cài từng gói (nhanh hơn cài cùng lúc)
pip install pipecat-ai
pip install "pipecat-ai[webrtc]"
pip install "pipecat-ai[google]"
pip install fastapi uvicorn google-generativeai
pip install "protobuf>=6.31.1,<7"
```

### 3.4. Cài TURN server (coturn)
```bash
sudo apt install -y coturn

# Config coturn
sudo tee /etc/turnserver.conf << 'EOF'
listening-port=3478
fingerprint
lt-cred-mech
user=test:test123
realm=myserver
total-quota=100
stale-nonce=600
log-file=/var/log/turnserver/nohup.log
simple-log
EOF

# Tạo thư mục log
sudo mkdir -p /var/log/turnserver
sudo chown turnserver:turnserver /var/log/turnserver

# Bật và start coturn
sudo systemctl stop coturn
sudo sed -i 's/#TURNSERVER=1/TURNSERVER=1/' /etc/default/coturn
sudo systemctl start coturn
sudo systemctl enable coturn
sudo systemctl status coturn
```

---

## 4. SERVER CODE

### 4.1. File: `~/pipecat-server/ws_server.py`

```python
import asyncio
import json
import logging
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# Pipecat imports
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.transports.base_transport import TransportParams
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection, IceServer

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────
# Service Factories
# ──────────────────────────────────────────────────────────────
def create_stt_service(provider: str, api_key: str):
    if provider == "openai":
        from pipecat.services.openai import OpenAISTTService
        return OpenAISTTService(api_key=api_key)
    elif provider == "deepgram":
        from pipecat.services.deepgram import DeepgramSTTService
        return DeepgramSTTService(api_key=api_key)
    else:
        raise ValueError(f"Unsupported STT provider: {provider}")

def create_llm_service(provider: str, api_key: str, model: str):
    if provider == "openai":
        from pipecat.services.openai import OpenAILLMService
        return OpenAILLMService(api_key=api_key, model=model)
    else:
        raise ValueError(f"Unsupported LLM provider: {provider}")

def create_tts_service(provider: str, api_key: str):
    if provider == "elevenlabs":
        from pipecat.services.elevenlabs import ElevenLabsTTSService
        return ElevenLabsTTSService(api_key=api_key)
    else:
        raise ValueError(f"Unsupported TTS provider: {provider}")

# ──────────────────────────────────────────────────────────────
# FastAPI App
# ──────────────────────────────────────────────────────────────
app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Track active connections
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
    """Khởi tạo và chạy pipeline Pipecat WebRTC"""

    # 1. Tạo WebRTC connection
    webrtc_connection = SmallWebRTCConnection(ice_servers=ICE_SERVERS)

    # 2. Initialize với SDP offer từ client
    await webrtc_connection.initialize(sdp=sdp_offer, type="offer")

    # Log local ICE candidates
    answer = webrtc_connection.get_answer()
    if answer:
        import re
        candidates = re.findall(r'a=candidate:.+', answer.get("sdp", ""))
        logger.info(f"Server local candidates ({len(candidates)}):")
        for c in candidates:
            logger.info(f"  {c}")
    else:
        logger.warning("No SDP answer generated!")

    # 3. Tạo transport với connection
    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    )

    processors = [transport.input()]

    app_mode = config.get("mode", "")

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
                system_instruction=config.get("prompt", "You are a helpful translator."),
                voice=config.get("voice", "Aoede"),
            ),
        )

        processors.append(llm)
        logger.info(f"Đã nạp Gemini Live (Model: {model_name})")
    else:
        stt_config = config.get("stt")
        if stt_config:
            processors.append(create_stt_service(stt_config["provider"], stt_config["api_key"]))

        llm_config = config.get("llm")
        if llm_config:
            processors.append(create_llm_service(llm_config["provider"], llm_config["api_key"], llm_config["model"]))

        tts_config = config.get("tts")
        if tts_config:
            processors.append(create_tts_service(tts_config["provider"], tts_config["api_key"]))

    processors.append(transport.output())

    pipeline = Pipeline(processors)
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            allow_interruptions=True,
            enable_metrics=True,
        ),
    )

    # 4. Chạy pipeline trong background
    async def run_pipeline():
        runner = PipelineRunner()
        await runner.run(task)

    asyncio.create_task(run_pipeline())

    # 5. Track connection để cleanup sau này
    answer = webrtc_connection.get_answer()
    pcs_map[answer["pc_id"]] = webrtc_connection

    @webrtc_connection.event_handler("closed")
    async def handle_closed(conn: SmallWebRTCConnection):
        logger.info(f"Connection closed: {conn.pc_id}")
        pcs_map.pop(conn.pc_id, None)

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
```

---

## 5. CHẠY SERVER

```bash
cd ~/pipecat-server
source venv/bin/activate
python ws_server.py
```

### Kết quả thành công
```
INFO:     Uvicorn running on http://0.0.0.0:3000
INFO:     Application startup complete.
```

### Test kết nối
```bash
# Từ laptop
curl http://35.199.170.99:3000/health -UseBasicParsing

# Kết quả mong đợi
{"status":"healthy"}
```

---

## 6. FLUTTER APP CONFIG

| Setting | Giá trị |
|---------|---------|
| Server URL | `http://35.199.170.99:3000` |
| Mode | `gemini_live` |
| Model | `gemini-2.0-flash-live-001` |

---

## 7. LỖI ĐÃ GẶP VÀ FIX

| Lỗi | Nguyên nhân | Cách fix |
|------|-------------|----------|
| `nano: command not found` | Ubuntu minimal không có nano | `sudo apt install nano` |
| `IceServer is not defined` | Sai import path | `from pipecat.transports.smallwebrtc.connection import IceServer` |
| `No module named 'pipecat'` | Chưa cài pipecat | `pip install pipecat-ai` |
| `libGL.so.1: cannot open` | Thiếu thư viện OpenCV | `sudo apt install -y libgl1-mesa-glx` |
| `No module named 'google.genai'` | Thiếu Google module | `pip install "pipecat-ai[google]"` |
| `protobuf version conflict` | Version không tương thích | `pip install "protobuf>=6.31.1,<7"` |

---

## 8. VẤN ĐỀ HIỆN TẠI

### ✅ Đã hoạt động
- Server chạy trên port 3000
- WebRTC connection thành công
- ICE gathering thành công (host, srflx, relay)
- Kết nối Gemini Live thành công
- Pipeline đã link

### ❌ Cần debug
- Nói vào mic nhưng không thấy phản hồi từ Gemini
- Có thể do model name (`gemini-3.1-flash-live-preview` → `gemini-2.0-flash-live-001`)

---

## 9. LỆNH HỮU ÍCH

### Kiểm tra server
```bash
# Test health endpoint
curl http://localhost:3000/health

# Kiểm tra port đang listen
ss -tlnp | grep 3000

# Kiểm tra coturn
sudo systemctl status coturn

# Xem log coturn
sudo journalctl -u coturn -f
```

### Quản lý server
```bash
# Chạy server (foreground)
cd ~/pipecat-server && source venv/bin/activate && python ws_server.py

# Chạy server (background)
nohup python ws_server.py > server.log 2>&1 &

# Dừng server
pkill -f ws_server.py

# Xem log server
tail -f server.log
```

### Cài thêm packages
```bash
source ~/pipecat-server/venv/bin/activate
pip install <package_name>
```

---

## 10. TÀI KHOẢN TWILIO TURN (đã tạo trước đó)

```
Account SID: AC842a51114f6bfe562097cf1abcf0220f
Username: 01dcf15dd91338c8a372763a39caeec3a89ca541a4261064a8b2518e878dbc30
Credential: LtlLcrmeBVH2JssPth2mix1scsaeoy/N1G8Y6Qknc18=
```

> **Lưu ý**: Hiện tại dùng TURN local trên VM (coturn) thay vì Twilio TURN.

---

## 11. SERVER CODE MỚI - ĐÃ HOẠT ĐỘNG (Cập nhật 2026-05-10)

### Tình trạng
- ✅ AI phản hồi âm thanh (Bot started/stopped speaking)
- ❌ Server không transcript được audio từ user

### Code mới (ws_server.py) - Dùng LLMContext + LLMContextAggregatorPair

```python
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
    IceServer(urls="stun:stun.l.google.com:19302"),
    IceServer(urls="stun:stun1.l.google.com:19302"),
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
        raw_model = "gemini-3.1-flash-live-preview"
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


if __name__ == "__main__":
    uvicorn.run(
        "ws_server:app",
        host="0.0.0.0",
        port=3000,
        reload=True,
        log_level="info",
    )
```

### Log thành công (2026-05-10 14:48)
```
INFO:ws_server:Client connected -> Ép AI cất tiếng chào!
DEBUG: GeminiLiveLLMService#0 TTFB: 0.734s
DEBUG: Bot started speaking
DEBUG: Bot stopped speaking
```

### Vấn đề còn lại
- Server nhận audio từ Flutter (RTP packets OK)
- AI phản hồi âm thanh được
- Nhưng server không transcript/user text từ audio

### Bước tiếp theo
1. Kiểm tra Gemini Live có hỗ trợ transcript không
2. Hoặc thêm STT service (Deepgram/Google Speech) vào pipeline
3. Kiểm tra Flutter app có gửi audio đúng format không

---

## 12. BƯỚC TIẾP THEO (TODO)

### Ngày mai (2026-05-11)
- [ ] Thêm STT service vào pipeline để transcript user audio
- [ ] Kiểm tra Gemini Live config để bật transcript output
- [ ] Test audio flow: User nói → Server transcript → AI trả lời
- [ ] Cập nhật Flutter app hiển thị transcript
