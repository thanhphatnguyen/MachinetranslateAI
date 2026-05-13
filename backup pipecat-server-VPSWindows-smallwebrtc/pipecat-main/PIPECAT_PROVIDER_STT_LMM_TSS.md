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

## Tìm hiểu: Android Audio System với Bluetooth

### Các thanh âm lượng trên Android

Khi kết nối Bluetooth, Android có các **thanh âm lượng riêng biệt**:

| Thanh âm lượng | Android Usage | Khi nào dùng |
|---|---|---|
| **Media** | `USAGE_MEDIA` | Nhạc, video, game |
| **Trợ lý AI** | `USAGE_ASSISTANT` | Google Assistant, AI voice |
| **Gọi điện** | `USAGE_VOICE_COMMUNICATION` | Phone call, WebRTC |
| **Chuông** | `USAGE_NOTIFICATION_RINGTONE` | Chuông báo |
| **Thông báo** | `USAGE_NOTIFICATION` | Nhạc báo |
| **Hệ thống** | `USAGE_ASSISTANCE_SONIFICATION` | Âm hệ thống (click, beep) |

### WebRTC mặc định dùng cái nào?

**WebRTC trên Android** sử dụng:
- `AudioAttributes.USAGE_VOICE_COMMUNICATION`
- `CONTENT_TYPE_SPEECH`

→ WebRTC đi theo thanh **"Gọi điện" (Call volume)**, KHÔNG phải Media hay Trợ lý AI.

### Luồng audio khi kết nối Bluetooth

```
┌─────────────────────────────────────────────────┐
│  Android Audio System                           │
├─────────────────────────────────────────────────┤
│                                                 │
│  Thanh Media ──────────► Loa BT (nhạc, video)  │
│                                                 │
│  Thanh Trợ lý AI ─────► Loa BT (assistant)     │
│                                                 │
│  Thanh Gọi điện ──────► Loa BT (WebRTC, call)  │  ← WebRTC mặc định
│                                                 │
│  Thanh Chuông ────────► Loa BT (ringtone)      │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Giải pháp ép audio sang thanh khác

Để ép audio sang thanh **Media** hoặc **Trợ lý AI** thay vì **Gọi điện**:

1. **Platform Channel**: Gọi Android `AudioManager` trực tiếp từ Kotlin
2. **Set AudioAttributes**: Dùng `USAGE_MEDIA` hoặc `USAGE_ASSISTANT`
3. **Set Audio Mode**: `AudioManager.MODE_IN_COMMUNICATION` (cho WebRTC)

### Code Android AudioAttributes

```kotlin
// Media
AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_MEDIA)
    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
    .build()

// Trợ lý AI
AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_ASSISTANT)
    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
    .build()

// Gọi điện (WebRTC default)
AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
    .build()
```

### Cách kiểm chứng

1. Kết nối Bluetooth
2. Chạy app, nói chuyện với AI
3. Nhấn nút volume trên điện thoại
4. Thấy thanh "Gọi điện" hoặc "Đang phát" hiện ra
5. Kéo thanh đó để chỉnh âm lượng loa Bluetooth

### Implement trong project

**Files đã sửa**:
- `lib/models/ai_translate_config.dart`: Thêm `AudioOutputOption`, `AudioStreamType`
- `lib/screens/ai_translate_screen.dart`: UI chọn output audio
- `lib/services/pipecat_service.dart`: Áp dụng audio route
- `android/.../MainActivity.kt`: Platform channel cho Android AudioAttributes
