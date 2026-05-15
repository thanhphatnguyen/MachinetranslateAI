# Phân tích dự án MachinetranslateAI

## Tổng quan

MachinetranslateAI là ứng dụng Flutter đa nền tảng, hướng đến dịch máy và dịch giọng nói bằng AI. Dự án hiện có 2 nhánh tính năng chính:

- **AI Live Translate**: nghe micro trong foreground/background, gửi audio lên Google Gemini Live qua WebSocket, nhận audio phản hồi và phát ra loa.
- **Offline Translate**: giao diện dịch offline theo hướng STT -> MT -> TTS, hiện mới hoàn thành UI và TTS hệ thống; STT/MT vẫn là TODO.

## Công nghệ và phụ thuộc

- **Framework**: Flutter, Dart SDK `^3.11.5`.
- **State/UI**: StatefulWidget có animation controller trực tiếp, chưa dùng state management riêng.
- **Realtime AI**: `web_socket_channel` kết nối Gemini Live API.
- **Lưu cấu hình**: `shared_preferences` lưu API key, model, prompt.
- **Background**: `flutter_background_service` và `flutter_local_notifications` để chạy foreground service trên Android.
- **Audio input**: `record` thu PCM 16-bit, 16 kHz, mono.
- **Audio output**: `audioplayers` phát byte WAV từ RAM.
- **Permission**: `permission_handler` xin quyền microphone và notification.
- **Offline/TTS**: `flutter_tts`; đã khai báo thêm `sherpa_onnx`, `llamadart`, `path_provider`, `http` nhưng chưa tích hợp logic chính.
- **Icon**: `flutter_launcher_icons`, asset chính `assets/icon.png`.

## Cấu trúc thư mục

```
lib/
  main.dart
  screens/
    home_screen.dart
    gemini_live_screen.dart
    ai_translate_screen.dart        # Màn hình AI Translate (dùng PipecatService WebSocket)
    offline_translate_screen.dart
  services/
    pipecat_service.dart            # WebSocket client kết nối Pipecat server
    gemini_socket_service.dart      # WebSocket trực tiếp đến Gemini Live API
    audio_stream_service.dart
    audio_player_service.dart
    tts_service.dart
    ...
  models/
    ai_translate_config.dart        # Config model (2 mode: sttLlmTts, geminiLive)
```

## Phân tích chi tiết các file chính

### `lib/services/pipecat_service.dart`

Đây là WebSocket client kết nối đến một **Pipecat Python server** (không phải trực tiếp đến Gemini).

**Protocol tin nhắn** (JSON qua WebSocket):
- **Client gửi**: `config` (cấu hình mode, API keys, model), `text` (tin nhắn text), audio bytes (binary)
- **Server gửi**: `transcript`, `bot_output`, `bot_transcript`, `user_transcript`, `llm_text`, `error`, `connected`, `bot_ready`, `speaking`

**Luồng kết nối**:
1. Chuyển `serverUrl` thành WebSocket URL (thêm `/ws`)
2. Gửi config message với mode (`gemini_live` hoặc `stt_llm_tts`) + API keys
3. Lắng nghe stream, phân loại message theo type
4. Phát audio từ bot qua `AudioPlayerService`

**Streams cung cấp**:
- `connectionState` - trạng thái kết nối (connecting/connected/disconnected/error)
- `transcripts` - transcript từ user và bot
- `botOutput` - text output từ bot
- `errors` - lỗi
- `audioLevel` - mức âm thanh (khi nhận binary data)

### `lib/screens/ai_translate_screen.dart`

Màn hình chat-style cho AI Translate:
- Hiển thị messages (user, bot, system, error)
- Nút Kết nối/Ngắt kết nối
- Nút Mic bật/tắt
- Settings modal: Server URL, Mode (STT+LLM+TTS hoặc Gemini Live), API keys, Model, Voice, Prompt
- Sử dụng `PipecatService` để giao tiếp với server

### `lib/models/ai_translate_config.dart`

**2 chế độ**:
- `sttLlmTts`: 3 dịch vụ riêng (STT + LLM + TTS), chọn provider cho từng dịch vụ
- `geminiLive`: Google Gemini xử lý audio trực tiếp

**Gemini Live config**: `googleApiKey`, `geminiModel` (default: `gemini-2.0-flash-live-001`), `geminiVoice` (default: `Aoede`), `geminiPrompt`

---

## Tham chiếu kỹ thuật: Pipecat SmallWebRTCTransport

**Nguồn**: https://docs.pipecat.ai/api-reference/server/services/transport/small-webrtc

### SmallWebRTCTransport là gì?

Transport WebRTC peer-to-peer (P2P), **không cần infrastructure trung gian** (không cần Daily, LiveKit). Client kết nối trực tiếp đến Pipecat server qua WebRTC.

### Đặc điểm chính

- **Serverless Architecture**: Kết nối P2P, không qua server trung gian xử lý media
- **Production Ready**: Đã được test kỹ, dùng trong nhiều Pipecat examples
- **Bidirectional Media**: Full-duplex audio và video streaming
- **Data Channels**: Hỗ trợ messaging qua WebRTC data channel
- **Không cần API key**: Vì là P2P transport

### Cài đặt (Server-side Python)

```bash
uv add "pipecat-ai[webrtc]"
```

### Cấu hình

```python
from pipecat.transports.base_transport import TransportParams
from pipecat.transports.network.small_webrtc import SmallWebRTCTransport

transport = SmallWebRTCTransport(
    webrtc_connection=webrtc_connection,
    params=TransportParams(
        audio_in_enabled=True,
        audio_out_enabled=True,
    ),
)
```

### Event Handlers

| Event | Mô tả |
|-------|--------|
| `on_client_connected` | Client WebRTC connection đã thiết lập |
| `on_client_disconnected` | Client WebRTC connection đã đóng |
| `on_app_message` | Nhận message từ client qua data channel |

### ICE Servers Configuration

WebRTC dùng ICE (Interactive Connectivity Establishment) để tìm đường mạng tốt nhất giữa 2 peers:

- **STUN**: Giúp client discover public IP khi behind NAT
- **TURN**: Relay fallback khi direct connection không khả dụng

| Scenario | STUN | TURN |
|----------|------|------|
| Cùng mạng local | Không | Không |
| Khác mạng (Linux) | Có | Thường không |
| Khác mạng (macOS / strict NAT) | Có | Có |
| Docker trên macOS | Có | Có |
| Production | Có | Khuyến nghị có |

```python
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection, IceServer

webrtc_connection = SmallWebRTCConnection(
    ice_servers=[
        IceServer(urls=["stun:stun.l.google.com:19302"]),
        IceServer(
            urls=["turn:your-turn-server.example.com:3478"],
            username="your-username",
            credential="your-password",
        ),
    ]
)
```

### Luồng Signaling

1. Client gửi SDP offer đến server endpoint (`POST /api/offer`)
2. Server tạo `SmallWebRTCConnection`, khởi tạo với SDP
3. Server trả về SDP answer + ICE candidates
4. Bot chạy trong background task kết nối với WebRTC connection

```python
@app.post("/api/offer")
async def offer(request: dict, background_tasks: BackgroundTasks):
    pipecat_connection = SmallWebRTCConnection(ice_servers)
    await pipecat_connection.initialize(sdp=request["sdp"], type=request["type"])

    @pipecat_connection.event_handler("closed")
    async def handle_disconnected(webrtc_connection):
        pcs_map.pop(webrtc_connection.pc_id, None)

    background_tasks.add_task(run_bot, pipecat_connection)
    return pipecat_connection.get_answer()
```

### SCTP Chunk Size

- Default: `1100` bytes
- Giảm nếu data channel bị stall (IPv6, Tailscale, VPN với MTU thấp)
- Chỉ tăng nếu trên LAN có kiểm soát với MTU 1500

---

## Tham chiếu kỹ thuật: Gemini Live (Pipecat Server-side)

**Nguồn**: https://docs.pipecat.ai/api-reference/server/services/s2s/gemini-live

### GeminiLiveLLMService là gì?

Dịch vụ conversation real-time speech-to-speech với Google Gemini, tích hợp sẵn audio transcription, VAD, context management.

### Đặc điểm chính

- **Multimodal**: Xử lý audio, video, text cùng lúc
- **Real-time Streaming**: Độ trễ thấp
- **Voice Activity Detection**: Server-side VAD hoặc local Silero VAD
- **Function Calling**: Tích hợp tools/API bên ngoài
- **Context Management**: Lịch sử hội thoại, system instruction

### Cài đặt

```bash
uv add "pipecat-ai[google]"
```

### Cấu hình cơ bản

```python
import os
from pipecat.services.google.gemini_live import GeminiLiveLLMService

llm = GeminiLiveLLMService(
    api_key=os.getenv("GOOGLE_API_KEY"),
    settings=GeminiLiveLLMService.Settings(
        voice="Charon",
        system_instruction="You are a helpful assistant.",
    ),
)
```

### Settings chi tiết

| Parameter | Type | Default | Mô tả |
|-----------|------|---------|--------|
| `model` | str | `models/gemini-2.5-flash-native-audio-preview-12-2025` | Model identifier |
| `system_instruction` | str | None | System prompt |
| `temperature` | float | NOT_GIVEN | Sampling temperature (0.0-2.0) |
| `max_tokens` | int | NOT_GIVEN | Maximum tokens |
| `voice` | str | NOT_GIVEN | TTS voice (Charon, Puck, v.v.) |
| `modalities` | GeminiModalities | NOT_GIVEN | AUDIO hoặc TEXT |
| `language` | str | NOT_GIVEN | Language for generation |
| `vad` | GeminiVADParams | NOT_GIVEN | Voice activity detection |
| `context_window_compression` | ContextWindowCompressionParams | NOT_GIVEN | Context compression |
| `thinking` | ThinkingConfig | NOT_GIVEN | Thinking/reasoning config |
| `enable_affective_dialog` | bool | NOT_GIVEN | Affective dialog |
| `proactivity` | ProactivityConfig | NOT_GIVEN | Proactivity settings |

### VAD Configuration

```python
from pipecat.services.google.gemini_live import GeminiVADParams

# Server-side VAD (default)
vad=GeminiVADParams(
    disabled=False,
    start_sensitivity=...,
    end_sensitivity=...,
    prefix_padding_ms=...,
    silence_duration_ms=500,
)

# Local VAD (Silero)
vad=GeminiVADParams(disabled=True)  # Disable server-side VAD
# + configure SileroVADAnalyzer trong LLMUserAggregatorParams
```

### Tính năng đặc biệt

- **Session Resumption**: Tự động reconnect với session handle
- **Connection Resilience**: Thử reconnect tối đa 3 lần
- **Transcription Aggregation**: Gemini Live gửi transcription theo chunks nhỏ, service tổng hợp thành câu hoàn chỉnh
- **Video Frame Rate**: Video throttled to 1 FPS
- **Affective Dialog & Proactivity**: Cần model hỗ trợ + API version `v1alpha`

---

## Tham chiếu kỹ thuật: Gemini Live API Reference (Server-side)

**Nguồn**: https://reference-server.pipecat.ai/en/latest/api/pipecat.services.google.gemini_live.llm.html

### Classes chính

| Class | Mô tả |
|-------|--------|
| `GeminiLiveLLMService` | Main service class |
| `GeminiLiveLLMSettings` | Settings (voice, modalities, language, VAD, etc.) |
| `GeminiModalities` | Enum: AUDIO, TEXT |
| `GeminiMediaResolution` | Enum: UNSPECIFIED, LOW, MEDIUM, HIGH |
| `GeminiVADParams` | VAD config (disabled, sensitivity, padding, silence) |
| `ContextWindowCompressionParams` | Compression config (enabled, trigger_tokens) |
| `InputParams` | Deprecated, dùng Settings thay thế |

### Methods chính

| Method | Mô tả |
|--------|--------|
| `create_client()` | Tạo Gemini API client |
| `start()` | Bắt đầu service |
| `stop()` | Dừng service |
| `cancel()` | Hủy operation |
| `process_frame()` | Xử lý frame |
| `set_audio_input_paused()` | Bật/tắt audio input |
| `set_video_input_paused()` | Bật/tắt video input |
| `set_model_modalities()` | Đổi modality |
| `set_language()` | Đổi ngôn ngữ |

---

## Phân tích vấn đề SmallWebRTC trong ai_translate_screen

### Trạng thái hiện tại

1. **`pipecat_service.dart`**: Dùng WebSocket trực tiếp (`web_socket_channel`) kết nối đến Pipecat server, **KHÔNG dùng pipecat Flutter plugin**
2. **`pipecat: ^0.2.0` pub.dev**: Plugin bị hỏng vì dependency `ai.pipecat:*:1.2.0` chưa publish lên Maven Central
3. **`ai.pipecat:small-webrtc-transport:1.1.0`**: Có sẵn trên Maven Central, có thể dùng được

### Kiến trúc hiện tại vs mong muốn

**Hiện tại** (WebSocket):
```
Flutter App → WebSocket → Pipecat Server → Gemini Live API
```

**Mong muốn** (SmallWebRTC):
```
Flutter App → WebRTC P2P → Pipecat Server (SmallWebRTCTransport + GeminiLiveLLMService)
```

### Lợi ích của SmallWebRTC

- **Độ trễ thấp hơn**: WebRTC optimized cho real-time media
- **Echo cancellation, noise reduction**: Built-in audio processing
- **Turn detection thông minh**: Server-side VAD hoặc local Silero VAD
- **Reconnection tự động**: Tối đa 3 lần thử lại
- **Không cần xử lý audio thủ công**: Không cần WAV header, base64 encode/decode
- **Data channels**: Messaging qua WebRTC data channel

### Yêu cầu phía server

Cần Pipecat Python server với:
```python
from pipecat.pipeline.pipeline import Pipeline
from pipecat.transports.network.small_webrtc import SmallWebRTCTransport
from pipecat.services.google.gemini_live import GeminiLiveLLMService

transport = SmallWebRTCTransport(
    params=TransportParams(audio_in_enabled=True, audio_out_enabled=True),
    webrtc_connection=webrtc_connection,
)

llm = GeminiLiveLLMService(
    api_key=os.getenv("GOOGLE_API_KEY"),
    settings=GeminiLiveLLMService.Settings(
        voice="Charon",
        system_instruction="Bạn là trợ lý dịch thuật...",
    ),
)

pipeline = Pipeline([
    transport.input(),
    llm,
    transport.output(),
])
```

### Đề xuất

#### Phương án 1: Viết custom platform channel bridge (Khuyến nghị nếu muốn WebRTC ngay)

Thêm `ai.pipecat:small-webrtc-transport:1.1.0` và `ai.pipecat:client:1.1.0` vào `android/app/build.gradle.kts`.

Viết Kotlin bridge (~200-300 dòng) expose:
- `PipecatClient.create(transport, options)`
- `startBotAndConnect(endpoint)`
- `disconnect()`
- Streams: `onConnected`, `onDisconnected`, `onUserTranscript`, `onBotTranscript`, `onError`

**Ưu điểm**: WebRTC hoạt động, chỉ cần bridge tối giản.
**Nhược điểm**: Cần Pipecat server, không có iOS support.

#### Phương án 2: Tiếp tục dùng WebSocket trực tiếp (Khuyên dùng ngay)

Giữ nguyên `PipecatService` hiện tại, sửa lỗi compile, thêm reconnect/backoff.

**Ưu điểm**: Ít thay đổi nhất, không cần Pipecat server.
**Nhược điểm**: Không có lợi ích của WebRTC.

#### Phương án 3: Chờ pipecat Flutter plugin được fix

Khi SDK 1.2.0 được publish lên Maven Central, plugin sẽ hoạt động.

**Ưu điểm**: Không cần viết code mới.
**Nhược điểm**: Không biết khi nào upstream publish.

---

## Tham khảo

- SmallWebRTCTransport: https://docs.pipecat.ai/api-reference/server/services/transport/small-webrtc
- GeminiLiveLLMService: https://docs.pipecat.ai/api-reference/server/services/s2s/gemini-live
- Gemini Live API Reference: https://reference-server.pipecat.ai/en/latest/api/pipecat.services.google.gemini_live.llm.html
- Pipecat Android Transports: https://github.com/pipecat-ai/pipecat-client-android-transports
- Pipecat Context Hub (MCP docs tool): https://github.com/pipecat-ai/pipecat-context-hub
- Pipecat Client JS SmallWebRTC: https://docs.pipecat.ai/api-reference/client/js/transports/small-webrtc

---

## Hệ thống License Key cho AI Translate

### Tổng quan

Tính năng AI Translate bị khóa trên UI. Người dùng phải nhập license key để mở khóa. Key được xác thực bằng SHA-256 hash, lưu trữ local bằng SharedPreferences.

### Cấu trúc thư mục liên quan

```
lib/
  services/
    license_service.dart      # Service xử lý license (validate, hash, device binding, lưu trữ)
  widgets/
    license_dialog.dart       # UI popup nhập license key
    model_download_dialog.dart # Dialog download model offline
  screens/
    home_screen.dart          # Tích hợp kiểm tra license trước khi mở AI Translate
```

### Cấu trúc thư mục tổng thể dự án

```
lib/
  main.dart
  models/
    ai_translate_config.dart        # Config model (2 mode: sttLlmTts, geminiLive)
  screens/
    home_screen.dart                # Màn hình chính (chọn chế độ dịch)
    offline_translate_screen.dart   # Dịch offline (STT + MT + TTS)
    ai_translate_screen.dart        # Dịch AI (dùng Pipecat server)
    gemini_live_screen.dart         # Gemini Live (tạm ẩn)
  services/
    license_service.dart            # License key system với device binding
    service_manager.dart            # Quản lý trạng thái các service
    pipecat_service.dart            # WebSocket client kết nối Pipecat server
    gemini_socket_service.dart      # WebSocket trực tiếp đến Gemini Live API
    audio_stream_service.dart       # Streaming audio
    audio_player_service.dart       # Phát audio
    stt_service.dart                # Speech-to-Text
    mt_service.dart                 # Machine Translation (offline)
    tts_service.dart                # Text-to-Speech
    unified_background_service.dart # Background service tổng hợp
  widgets/
    license_dialog.dart             # Popup nhập license key
    model_download_dialog.dart      # Dialog download model offline
```

### Luồng hoạt động

```
[Chạm AI Translate trên Home]
        │
        ▼
[LicenseService.isLicensed()] ──── Có key hợp lệ ───→ [Mở AiTranslateScreen]
        │
        ▼
    Chưa có key
        │
        ▼
[Hiện LicenseDialog popup]
        │
        ▼
[Nhập key → Validate]
        │
    ┌───┴───┐
    ▼       ▼
 Hợp lệ   Sai
    │       │
    ▼       ▼
 Lưu key  Hiện lỗi
 Mở screen
```

### File: `lib/services/license_service.dart`

**Các thành phần chính:**

| Thành phần | Mô tả |
|-----------|-------|
| `LicenseStatus` | Enum: `valid`, `invalid`, `expired`, `notActivated`, `deviceMismatch` |
| `LicenseResult` | Class chứa status + message |
| `_validKeys` | Map chứa key hợp lệ (đã hash SHA-256) |
| `_secretPrefix` | Prefix bí mật dùng để hash (`MTAI-2026`) |

**Các method:**

| Method | Mô tả |
|--------|-------|
| `validateKey(String key)` | Kiểm tra key có hợp lệ không (chỉ validate format) |
| `saveLicense(String key)` | Lưu key + deviceId vào SharedPreferences |
| `isLicensed()` | Kiểm tra đã có license chưa (bao gồm device binding) |
| `checkLicense()` | Kiểm tra license chi tiết (trả về status cụ thể) |
| `getSavedKey()` | Lấy key đã lưu |
| `getDeviceId()` | Lấy device ID unique cho thiết bị hiện tại |
| `clearLicense()` | Xóa license (reset) |
| `generateKey()` | Tạo key mới (dùng để cấp key) |

**Cách hash key:**
```dart
static String _hashKey(String key) {
  final input = '$_secretPrefix:${key.toUpperCase().trim()}';
  return sha256.convert(utf8.encode(input)).toString();
}
```

### Device Binding (Chống share key)

Key được ràng buộc với thiết bị. Mỗi key chỉ hoạt động trên 1 thiết bị.

**Luồng device binding:**
```
[Máy A: Nhập key MTAI-DEMO-KEY-0001]
        │
        ▼
validateKey() → Hợp lệ
        │
        ▼
saveLicense() → Lưu key + deviceId máy A
        │
        ▼
Mở khóa thành công ✓

[Máy B: Nhập key MTAI-DEMO-KEY-0001]
        │
        ▼
validateKey() → Hợp lệ
        │
        ▼
checkLicense() → deviceId khác → deviceMismatch
        │
        ▼
"Key đã được sử dụng trên thiết bị khác" ✗
```

**Lấy deviceId theo nền tảng:**

| Platform | Method | ID |
|----------|--------|-----|
| Android | `deviceInfo.androidInfo.id` | Android ID |
| iOS | `deviceInfo.iosInfo.identifierForVendor` | Vendor ID |
| Windows | `deviceInfo.windowsInfo.deviceId` | Device ID |
| macOS | `deviceInfo.macOsInfo.systemGUID` | System GUID |
| Linux | `deviceInfo.linuxInfo.machineId` | Machine ID |

**Package dependencies cho device binding:**
```yaml
dependencies:
  crypto: ^3.0.6           # SHA-256 hash
  device_info_plus: ^11.3.0 # Lấy device info
```

### File: `lib/widgets/license_dialog.dart`

Popup dialog cho phép người dùng nhập key:
- TextField với hint `XXXX-XXXX-XXXX-XXXX`
- Tự động capitalize chữ
- Nút "KÍCH HOẠT" gọi `LicenseService.validateKey()`
- Nút "Hủy" đóng dialog
- Hiển thị lỗi khi key sai

**Cách sử dụng:**
```dart
final licensed = await LicenseDialog.show(context);
if (licensed) {
  // Key hợp lệ, mở tính năng
}
```

### File: `lib/screens/home_screen.dart`

Đoạn code tích hợp kiểm tra license (dòng ~258-277):

```dart
onTap: () async {
  if (!isGeminiRunning && !isOfflineRunning) {
    final isLicensed = await LicenseService.isLicensed();
    if (!isLicensed && mounted) {
      final licensed = await LicenseDialog.show(context);
      if (!licensed) return;
    }
    if (mounted) {
      _navigateTo(const AiTranslateScreen());
    }
  }
},
```

### Cách thêm key mới cho khách

1. Mở file `lib/services/license_service.dart`
2. Tìm biến `_validKeys` (dòng ~35)
3. Thêm entry mới:
```dart
static final Map<String, String> _validKeys = {
  'MTAI-DEMO-KEY-0001': _hashKey('MTAI-DEMO-KEY-0001'),
  'KEY-KHACH-HANG-001': _hashKey('KEY-KHACH-HANG-001'),  // Thêm dòng này
};
```
4. Rebuild app

### Format key

- Prefix: `MTAI-` (MachineTranslateAI)
- 3 segments, mỗi segment 4 ký tự alphanumeric
- Ví dụ: `MTAI-XXXX-YYYY-ZZZZ`

### Key demo để test

```
MTAI-DEMO-KEY-0001
```

### Package dependencies

Thêm vào `pubspec.yaml`:
```yaml
dependencies:
  crypto: ^3.0.6            # SHA-256 hash
  device_info_plus: ^11.3.0 # Lấy device info cho device binding
```

### SharedPreferences keys

| Key | Type | Mô tả |
|-----|------|-------|
| `ai_translate_license_key` | String | License key đã kích hoạt |
| `ai_translate_license_activated_at` | String | Thời gian kích hoạt (ISO 8601) |
| `ai_translate_license_device_id` | String | Device ID đã绑定 (chống share key) |

### Mở rộng trong tương lai

- **License theo thời hạn**: Thêm trường `expiresAt`, kiểm tra khi `isLicensed()`
- **Server-side validation**: Gọi API server để validate thay vì hardcode
- **In-app purchase**: Tích hợp Google Play / App Store billing
- **QR Code**: Quét QR để nhập key tự động
- **Remote key management**: Quản lý key từ server, revoke key từ xa

---

## UI Design System

### Color Palette (White + Sky Blue Theme)

| Màu | Hex | RGB | Dùng cho |
|-----|-----|-----|----------|
| Sky Blue | `#0EA5E9` | `14, 165, 233` | Primary, buttons, highlights |
| Light Blue | `#38BDF8` | `56, 189, 248` | Gradient accents |
| Pale Blue | `#7DD3FC` | `125, 211, 252` | Soft backgrounds |
| Background | `#F8FAFC` | `248, 250, 252` | Nền chính |
| Surface | `#FFFFFF` | `255, 255, 255` | Cards, sheets |
| Text Primary | `#0F172A` | `15, 23, 42` | Title, body |
| Text Secondary | `#64748B` | `100, 116, 139` | Subtitle |
| Text Muted | `#94A3B8` | `148, 163, 184` | Placeholder |
| Border | `#E2E8F0` | `226, 232, 240` | Borders, dividers |
| Surface Hover | `#F1F5F9` | `241, 245, 249` | Hover states |
| Error | `#EF4444` | `239, 68, 68` | Error states |
| Success | `#10B981` | `16, 185, 129` | Bot avatar, success |

### Typography

| Element | Size | Weight | Color |
|---------|------|--------|-------|
| App Title | 28 | w800 | `#0F172A` |
| Section Title | 20 | w700 | `#0F172A` |
| Card Title | 17 | w700 | `#0F172A` |
| Body | 15 | w400 | `#0F172A` |
| Subtitle | 13 | w400 | `#64748B` |
| Caption | 12 | w500 | `#94A3B8` |
| Badge | 10 | w800 | white |

### Design Principles

- **Clean & Minimal**: Không dùng gradient đậm, ưu tiên background trắng/sáng
- **Card-based**: Cards với border nhẹ, shadow subtle
- **Rounded corners**: 12-20px cho cards, 24-27px cho buttons
- **Consistent spacing**: 8, 12, 16, 20, 24, 32px
- **Blue accents**: Dùng `#0EA5E9` cho interactive elements
- **Muted secondary text**: Dùng `#94A3B8` cho placeholder/hint

### Screens đã áp dụng

- `home_screen.dart` - White background, blue logo, card-based layout
- `offline_translate_screen.dart` - White AppBar, blue chat bubbles
- `ai_translate_screen.dart` - White settings sheet, blue buttons

---

## Kiến trúc Pro Translate Mode

### Tổng quan

Pro Translate là mode dịch thuật chuyên nghiệp dùng Soniox STT (realtime translation) + Piper TTS, không qua LLM.

### Pipeline (Server)
```
transport.input() → SonioxRealtimeTranslationSTT → PiperTTSService → transport.output()
```

### Luồng dữ liệu
```
[Flutter mic] → WebRTC audio → [Server]
    → SonioxRealtimeTranslationSTT
        → Gửi audio PCM lên Soniox WebSocket
        → Nhận translation tokens
        → Gom thành câu (flush khi gặp dấu câu)
        → Đẩy TextFrame cho Piper TTS
        → Gửi transcript qua data channel (send_app_message)
    → PiperTTSService
        → Nhận TextFrame
        → Generate audio (Piper local model)
        → Đẩy AudioRawFrame
    → transport.output()
        → Gửi audio về Flutter qua WebRTC
```

### Config model (`ai_translate_config.dart`)
```dart
enum TranslateMode { sttLlmTts, geminiLive, proTranslate }

// Pro Translate fields
String proSourceLanguage;      // "en"
String proTargetLanguage;      // "vi"
String proTranslationType;     // "one_way" hoặc "two_way"
String proSttApiKey;           // Soniox API key
bool proSttDiarize;            // phân biệt giọng nói
String proTtsModel;            // "vi_VN-vivos-x_low"
List<Map<String, String>> proSonioxContextGeneral;
List<String> proSonioxContextTerms;
List<Map<String, String>> proSonioxContextTranslationTerms;
```

### Message format (Data Channel → Flutter)
```json
{
    "type": "pro_translate",
    "data": {
        "speaker": "bot",
        "source": "How old are you?",
        "translation": "Bạn mấy tuổi?"
    }
}
```

### UI hiển thị (`ai_translate_screen.dart`)
- Pro Translate mode hiển thị box thay vì chat bubble
- Mỗi box có: Speaker label, source text, "Dich:", translation text
- `_buildProTranslateBubble()` method xử lý hiển thị

### Files liên quan
| File | Vai trò |
|------|---------|
| `ws_server_fixed.py` | Server: SonioxRealtimeTranslationSTT + PiperTTSService + data channel |
| `lib/models/ai_translate_config.dart` | Config model với 3 modes |
| `lib/screens/ai_translate_screen.dart` | UI: settings + transcript display |
| `lib/services/pipecat_service.dart` | Client: WebRTC + data channel handler |
| `lib/services/unified_background_service.dart` | Background service: forward transcript events |
| `lib/services/service_manager.dart` | Service lifecycle management |

### Thứ tự startup
```
1. Flutter: _startBackground()
2. UnifiedBackgroundService: startAiTranslate()
3. PipecatService.connect(config)
   → POST /connect với SDP offer + config
4. Server: start_pipecat_session()
   → Tạo pipeline (Soniox → Piper → Transport)
   → WebRTC handshake
5. Flutter: nhận SDP answer → set remote description
6. WebRTC connected → audio streaming bắt đầu
```
