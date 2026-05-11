# 📋 PIPECAT SMALLWEBRTC MIGRATION LOG
> **Ngày tạo**: 2026-05-08  
> **Mục đích**: Log chi tiết để AI khác tiếp tục nếu hết quota  
> **Trạng thái**: ✅ FINAL_V1_SUCCESS_RUN_VPS_REMOTE_WINDOWS

---

## ✅ FINAL_V1_SUCCESS_RUN_VPS_REMOTE_WINDOWS (Cập nhật 2026-05-11)

### 🎉 KẾT QUẢ: THÀNH CÔNG
- **VPS**: Windows Server 2022 (IP: 103.118.29.243)
- **Pipecat Server**: Python 3.12 + Pipecat 1.1.0
- **ICE Server**: STUN Google (`stun:stun.l.google.com:19302`)
- **WebRTC**: Hoạt động bình thường
- **Không cần**: pion/turn, TURN server

### 📋 CÀI ĐẶT TỪ ĐẦU ĐẾN CUỐI

#### Bước 1: Mở UDP trên Windows Firewall
```powershell
# Mở UDP 49152-65535 (WebRTC media)
New-NetFirewallRule -DisplayName "WebRTC UDP Range" `
  -Direction Inbound `
  -Protocol UDP `
  -LocalPort 49152-65535 `
  -Action Allow

# Mở TCP 3000 (Pipecat server)
New-NetFirewallRule -DisplayName "TCP 3000" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 3000 `
  -Action Allow
```

#### Bước 2: Cài Python 3.12
```powershell
# Download Python 3.12
# https://www.python.org/downloads/release/python-31210/

# Cài đặt, đảm bảo chọn "Add Python to PATH"
# Sau đó restart PowerShell
```

#### Bước 3: Tạo thư mục project
```powershell
mkdir C:\Project\pipecat-main
cd C:\Project\pipecat-main
```

#### Bước 4: Tạo virtual environment
```powershell
python -m venv venv
.\venv\Scripts\activate
```

#### Bước 5: Cài dependencies
```powershell
pip install "pipecat-ai[webrtc]" fastapi uvicorn google-generativeai
```

#### Bước 6: Copy source code
- Copy file `ws_server.py` vào `C:\Project\pipecat-main\`

#### Bước 7: Chạy Pipecat server
```powershell
cd C:\Project\pipecat-main
.\venv\Scripts\activate
python ws_server.py
```

#### Bước 8: Kiểm tra kết nối
```powershell
# Trên laptop
Test-NetConnection -ComputerName 103.118.29.243 -Port 3000
curl http://103.118.29.243:3000/health
curl http://103.118.29.243:3000/
```

#### Bước 9: Cập nhật Flutter app
- Server URL: `http://103.118.29.243:3000`

### 📝 LOG KIỂM TRA THÀNH CÔNG

```
PS C:\WINDOWS\system32> Test-NetConnection -ComputerName 103.118.29.243 -Port 3000

ComputerName     : 103.118.29.243
RemoteAddress    : 103.118.29.243
RemotePort       : 3000
InterfaceAlias   : Wi-Fi
SourceAddress    : 192.168.110.158
TcpTestSucceeded : True



PS C:\WINDOWS\system32> Test-NetConnection -ComputerName 103.118.29.243 -Port 3478

ComputerName     : 103.118.29.243
RemoteAddress    : 103.118.29.243
RemotePort       : 3478
InterfaceAlias   : Wi-Fi
SourceAddress    : 192.168.110.158
TcpTestSucceeded : True


PS C:\WINDOWS\system32> curl http://103.118.29.243:3000/health

StatusCode        : 200
StatusDescription : OK
Content           : {"status":"healthy"}


PS C:\WINDOWS\system32> curl http://103.118.29.243:3000/

StatusCode        : 200
StatusDescription : OK
Content           : {"status":"ok","message":"Pipecat WebRTC Server Active"}
```

### ⚠️ LƯU Ý QUAN TRỌNG

1. **ICE Server**: Dùng STUN Google (`stun:stun.l.google.com:19302`) là ĐỦ, không cần TURN local
2. **UDP**: Phải mở UDP trong Windows Firewall như script hướng dẫn trên
3. **Không cần pion/turn**: Chỉ cần Pipecat server là đủ
4. **Model**: Sử dụng `gemini-3.1-flash-live-preview` (model mới nhất)

### 🔧 SOURCE CODE ws_server.py

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

# Pipecat Context & Aggregators (Rất quan trọng cho luồng hội thoại liên tục)
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

# Quản lý các kết nối đang hoạt động
pcs_map: dict[str, SmallWebRTCConnection] = {}

# Cấu hình máy chủ STUN của Google (Giúp đục tường lửa NAT)
ICE_SERVERS = [
    IceServer(urls="stun:stun.l.google.com:19302"),
    IceServer(urls="stun:stun1.l.google.com:19302"),
]


async def start_pipecat_session(config: dict, sdp_offer: str):
    """Khởi tạo và chạy pipeline Pipecat WebRTC cho Speech-to-Speech"""

    # 1. Tạo WebRTC connection (CHƯA initialize để tránh lỗi nghẽn StartFrame)
    webrtc_connection = SmallWebRTCConnection(ice_servers=ICE_SERVERS)

    # 2. Tạo Transport hỗ trợ 2 chiều In/Out
    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    )
    logger.info("Transport WebRTC đã được tạo (Audio In/Out: Bật)")

    # Kiểm tra xem Flutter yêu cầu mode gì
    app_mode = config.get("mode", "gemini_live")

    if app_mode == "gemini_live":
        try:
            from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService
        except ImportError as e:
            logger.error(f"Chưa cài đặt đúng gói Google! Lỗi: {e}")
            raise

        api_key = config.get("google_api_key")
        # Đảm bảo format tên model chuẩn của Google (VD: models/gemini-2.0-flash-exp)
        raw_model = "gemini-3.1-flash-live-preview"
        model_name = f"models/{raw_model}" if not raw_model.startswith("models/") else raw_model

        # Khởi tạo não Gemini Live
        llm = GeminiLiveLLMService(
            api_key=api_key,
            settings=GeminiLiveLLMService.Settings(
                model=model_name,
                system_instruction=config.get("prompt", "Bạn là một trợ lý AI giao tiếp bằng giọng nói. Hãy trả lời ngắn gọn, tự nhiên bằng tiếng Việt."),
                voice=config.get("voice", "Aoede"), 
            ),
        )

        # 3. Tạo Bối cảnh (Context) để xúi AI chào hỏi ngay khi bắt đầu
        context = LLMContext(
            [
                {
                    "role": "user",
                    "content": "Hãy chào tôi một câu ngắn gọn bằng tiếng Việt để bắt đầu cuộc trò chuyện.",
                },
            ],
        )
        user_aggregator, assistant_aggregator = LLMContextAggregatorPair(context)

        # 4. Sắp xếp đường ống Pipeline theo chuẩn Speech-to-Speech
        processors = [
            transport.input(),          # Mic từ điện thoại gửi lên
            user_aggregator,            # Gom luồng âm thanh user
            llm,                        # Đưa vào AI xử lý
            transport.output(),         # Trả âm thanh từ AI về điện thoại
            assistant_aggregator        # Ghi nhận AI đã nói xong
        ]
        
        logger.info(f"Đã nạp não Gemini Live (Model: {model_name})")
    else:
        raise ValueError("File này hiện đang được tối ưu riêng cho chế độ gemini_live.")

    pipeline = Pipeline(processors)
    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            allow_interruptions=True, # Cho phép ngắt lời AI khi người dùng nói xen vào
            enable_metrics=True,
        ),
    )

    # 5. KÍCH HOẠT SỰ KIỆN: Khi WebRTC kết nối thành công, ép AI lên tiếng!
    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info("Client connected -> Ép AI cất tiếng chào!")
        await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("Client disconnected -> Tắt task AI.")
        await task.cancel()

    # 6. Chạy Pipeline trong Background (Để nó khởi động sẵn)
    runner = PipelineRunner()
    runner_task = asyncio.create_task(runner.run(task))

    # Chờ nửa giây để Pipeline có đủ thời gian khởi động và bơm StartFrame
    await asyncio.sleep(0.5)

    # 7. Initialize WebRTC bằng SDP Offer từ client
    logger.info("Đang đàm phán WebRTC (Signaling) với điện thoại...")
    await webrtc_connection.initialize(sdp=sdp_offer, type="offer")

    answer = webrtc_connection.get_answer()
    if not answer:
        raise Exception("Không thể tạo được SDP Answer từ server.")

    # In ra các cổng mạng (ICE Candidates) để tiện debug
    candidates = re.findall(r'a=candidate:.+', answer.get("sdp", ""))
    logger.info(f"Server local candidates ({len(candidates)}):")
    for c in candidates:
        logger.info(f"  {c}")

    # Track connection để dọn dẹp bộ nhớ sau này
    pcs_map[answer["pc_id"]] = webrtc_connection

    @webrtc_connection.event_handler("closed")
    async def handle_closed(conn: SmallWebRTCConnection):
        logger.info(f"WebRTC Connection closed: {conn.pc_id}")
        pcs_map.pop(conn.pc_id, None)
        task.cancel() # Hủy AI để không ngốn RAM VPS

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

## ⚠️ TIẾN ĐỘ HIỆN TẠI (đọc phần này trước)

### Đã hoàn thành ✅
1. AndroidManifest.xml — đã thêm permissions WebRTC
2. pubspec.yaml — đã thêm `flutter_webrtc: ^1.4.1`
3. `flutter pub get` — OK
4. `lib/services/pipecat_service.dart` — **viết lại hoàn toàn** (WebSocket → WebRTC)
5. `lib/models/ai_translate_config.dart` — đã thêm `buildConnectUrl()`
6. `lib/screens/ai_translate_screen.dart` — đã sửa `_toggleMic()` gọi `setMicEnabled()`
7. `flutter analyze` — 0 lỗi mới
8. `flutter build apk --debug` — OK
9. Server Python `ws_server.py` — đã sửa API (`SmallWebRTCConnection` + `initialize()`)

