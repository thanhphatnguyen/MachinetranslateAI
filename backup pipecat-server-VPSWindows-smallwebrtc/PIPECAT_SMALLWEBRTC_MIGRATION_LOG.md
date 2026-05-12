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


-----------------------------------------------------------------
# FIX lỗi liên quan đường truyền mạng , WIFI Cafe kết nối thành công nhưng 4g và wifi nhà thì không , bước fix bên dưới 

## Fix WebRTC ICE/NAT Traversal cho Pipecat SmallWebRTC + Flutter

### Môi trường
- **Server**: VPS Windows, chạy Python + Pipecat 1.1.0, SmallWebRTC transport
- **Client**: Flutter app, dùng `flutter_webrtc`
- **Thư viện WebRTC phía server**: `aiortc 1.14.0` + `aioice 0.10.2`
- **Triệu chứng**: Kết nối được ở WiFi cafe, FAIL ở 4G mobile và WiFi nhà (FPT)

---

### Nguyên nhân gốc rễ

#### 1. NAT Type khác nhau
| Môi trường | NAT Type | STUN đủ không? |
|---|---|---|
| WiFi cafe | Full Cone / Restricted | ✅ Đủ |
| 4G mobile | Symmetric NAT (carrier-grade) | ❌ Cần TURN |
| WiFi nhà (FPT) | Symmetric NAT | ❌ Cần TURN |

#### 2. UDP bị chặn hoàn toàn trên VPS
- VPS gửi UDP ra ngoài được nhưng **không nhận lại được response**
- Tất cả STUN/TURN UDP đều timeout
- TCP/80, TCP/443, TCP/3478 → hoạt động bình thường

#### 3. aiortc 1.14.0 chưa support `iceTransportPolicy`
- `RTCConfiguration` của aiortc **không có** tham số `iceTransportPolicy`
- Issue GitHub: https://github.com/aiortc/aiortc/issues/1397
- Server vẫn gather host candidates (`127.0.0.1`, `10.73.x.x`) dù đã cấu hình TURN
- Các host candidates này được đưa vào ICE pairs → check fail → timeout

#### 4. Flutter thiếu TURN config
- Flutter app chỉ có STUN Google → không gather relay candidates
- SDP offer gửi lên server không có `typ relay`
- Server không có candidate nào của mobile để pair với relay của nó

---

### Cơ chế ICE Pair Matching

ICE hoạt động theo kiểu **pair matching**:
```
Server liệt kê candidates: [host, srflx, relay]
Mobile liệt kê candidates: [host, srflx, relay]
→ Thử từng cặp (server_candidate ↔ mobile_candidate)
```

Với Symmetric NAT, chỉ có cặp **relay ↔ relay** mới kết nối được qua internet:
```
Trước fix:
  Server: relay ✅  ←→  Mobile: host(10.73.x.x) ❌  → FAIL

Sau fix:
  Server: relay ✅  ←→  Mobile: relay ✅  → CONNECTED ✅
```

---

### Giải pháp từng bước

#### Bước 1: Dùng TURN server có hỗ trợ TCP

Đăng ký TURN server tại https://dashboard.metered.ca (free 50GB/tháng).

Lý do dùng TCP: UDP bị chặn, TCP/443 luôn thông.

#### Bước 2: Cấu hình TURN TCP phía server (Python)

```python
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection, IceServer

ICE_SERVERS = [
    IceServer(
        urls="turn:asia.relay.metered.ca:80?transport=tcp",
        username="YOUR_USERNAME",
        credential="YOUR_CREDENTIAL",
    ),
    IceServer(
        urls="turn:asia.relay.metered.ca:443?transport=tcp",
        username="YOUR_USERNAME",
        credential="YOUR_CREDENTIAL",
    ),
]
```

**Lưu ý**: Bỏ hết STUN servers vì UDP timeout làm ICE negotiation chậm thêm 5-10 giây.

#### Bước 3: Monkey-patch aioice để force relay-only (Python)

`aiortc 1.14.0` chưa support `iceTransportPolicy="relay"` trong `RTCConfiguration`.
Giải pháp: patch `aioice.ice.Connection.gather_candidates` để filter sau khi gather.

```python
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
    print(f"ICE relay-only patch: {before} → {after} relay, bỏ {before - after} host/srflx")

_aioice_ice.Connection.gather_candidates = _relay_only_gather
```

**Đặt đoạn này TRƯỚC khi import pipecat** hoặc ngay sau logging setup.

**Tại sao cần patch này?**
- Nếu không patch, server vẫn gather `127.0.0.1` và `10.73.x.x`
- Các địa chỉ này được ghép thành ICE pairs với candidates của mobile
- Mobile không reach được các IP nội bộ của server → check fail hết → timeout
- Chỉ giữ relay thì ICE chỉ check đúng 1 pair relay↔relay → thành công

#### Bước 4: Cấu hình TURN + relay-only phía Flutter

```dart
final iceConfig = {
  'iceServers': [
    {
      'urls': 'turn:asia.relay.metered.ca:80?transport=tcp',
      'username': 'YOUR_USERNAME',
      'credential': 'YOUR_CREDENTIAL',
    },
    {
      'urls': 'turn:asia.relay.metered.ca:443?transport=tcp',
      'username': 'YOUR_USERNAME',
      'credential': 'YOUR_CREDENTIAL',
    },
  ],
  'iceTransportPolicy': 'relay', // Flutter/WebRTC native support param này
  'sdpSemantics': 'unified-plan',
};

_pc = await createPeerConnection(iceConfig);
```

**Lưu ý**: Flutter `flutter_webrtc` support `iceTransportPolicy` natively (khác với aiortc).

---

### File ws_server.py hoàn chỉnh (các phần quan trọng)

```python
import asyncio
import logging
import aioice.ice as _aioice_ice

logger = logging.getLogger(__name__)

# ── MONKEY-PATCH: relay-only ICE ──────────────────────────────
_original_gather = _aioice_ice.Connection.gather_candidates

async def _relay_only_gather(self):
    await _original_gather(self)
    before = len(self._local_candidates)
    self._local_candidates = [c for c in self._local_candidates if c.type == "relay"]
    after = len(self._local_candidates)
    logger.info(f"ICE relay-only patch: {before} → {after} relay, bỏ {before-after} host/srflx")

_aioice_ice.Connection.gather_candidates = _relay_only_gather
# ─────────────────────────────────────────────────────────────

from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection, IceServer

ICE_SERVERS = [
    IceServer(
        urls="turn:asia.relay.metered.ca:80?transport=tcp",
        username="YOUR_USERNAME",
        credential="YOUR_CREDENTIAL",
    ),
    IceServer(
        urls="turn:asia.relay.metered.ca:443?transport=tcp",
        username="YOUR_USERNAME",
        credential="YOUR_CREDENTIAL",
    ),
]

# Trong start_pipecat_session():
webrtc_connection = SmallWebRTCConnection(ice_servers=ICE_SERVERS)
```

---

### Checklist debug khi ICE fail

```
1. Log thấy "TURN allocation created" chưa?
   → Chưa: TURN server không connect được, kiểm tra credentials và TCP reachability

2. Log thấy "ICE relay-only patch: X → Y relay" chưa?
   → Chưa: monkey-patch chưa chạy, kiểm tra thứ tự import

3. SDP offer từ mobile có "typ relay" không?
   → Không: Flutter chưa cấu hình TURN hoặc iceTransportPolicy chưa đúng

4. ICE pairs có chỉ toàn relay↔relay không?
   → Còn host/local IP: một trong 2 phía chưa relay-only

5. "TURN channel bound" xuất hiện nhưng vẫn timeout?
   → Tăng connection_timeout_secs trong SmallWebRTCConnection
```

---

## Lý do TURN 401 error trong log là bình thường

```
aioice.stun.TransactionFailed: STUN transaction failed (401 - )
...
INFO:aioice.turn:TURN channel bound 16386  ← Thành công!
```

TURN authentication theo RFC 5766 dùng **2 bước**:
1. Client gửi request → Server trả 401 + nonce
2. Client gửi lại với credentials + nonce → Server chấp nhận

`aioice` log bước 1 (401) ra màn hình trông như lỗi nhưng thực ra là flow bình thường. Chỉ cần thấy `TURN channel bound` sau đó là OK.

---

## Môi trường test

| Test | Kết quả |
|---|---|
| UDP STUN/TURN | ❌ Timeout hoàn toàn |
| TCP/80 | ✅ OK |
| TCP/443 | ✅ OK |
| TURN TCP/80 | ✅ Relay allocated |
| TURN TCP/443 | ✅ Relay allocated |
| WebRTC connected (cafe) | ✅ |
| WebRTC connected (4G) | ✅ Sau fix |
| WebRTC connected (WiFi FPT) | ✅ Sau fix |







# Dùng PION để tạo Turn local
