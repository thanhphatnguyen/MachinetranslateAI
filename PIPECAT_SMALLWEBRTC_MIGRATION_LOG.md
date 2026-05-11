# 📋 PIPECAT SMALLWEBRTC MIGRATION LOG
> **Ngày tạo**: 2026-05-08  
> **Mục đích**: Log chi tiết để AI khác tiếp tục nếu hết quota  
> **Trạng thái**: 🟡 90% DONE — Cần deploy server lên VPS có UDP open

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

### Vấn đề còn lại ❌
**WebRTC ICE failed** — server không thể gather STUN/TURN candidates.

**Nguyên nhân**: Server đang chạy trên máy Windows mà **UDP inbound bị block** hoàn toàn:
- Windows Firewall đã mở (UDP 49152-65535)
- Nhưng router/ISP/security group cloud vẫn block UDP
- STUN request gửi đi nhưng không nhận response
- TURN server (OpenRelay) cũng không trả lời

**Bằng chứng**:
```
Server chỉ tạo 1 host candidate: 103.118.29.243:49991 typ host
Không có srflx (STUN) hay relay (TURN) candidates
ICE check tất cả FAILED
```

### Bước tiếp theo 🔜
**Deploy server lên VPS có UDP open**:
1. Vào dashboard nhà cung cấp VPS → Security Group → mở inbound UDP 49152-65535 (source 0.0.0.0/0)
2. Remote vào VPS → cài Python 3.12 + dependencies
3. Copy file `ws_server_fixed.py` lên VPS (rename thành `ws_server.py`)
4. Chạy `python test_stun.py` — phải thấy `srflx` candidate
5. Chạy `python ws_server.py`
6. Đổi URL trong Flutter app thành `http://<VPS_IP>:3000`
7. Test kết nối từ app

---

## 1. BỐI CẢNH DỰ ÁN

### Dự án Flutter: MachinetranslateAI
- Đường dẫn: `c:\MachinetranslateAI`
- Chức năng cần sửa: **AI Translate** (màn hình `ai_translate_screen.dart`)

### Kiến trúc hiện tại vs mới
| Hiện tại | Mới |
|---|---|
| Flutter → **WebSocket** (`web_socket_channel`) → Server | Flutter → **WebRTC** (`flutter_webrtc`) → Server |
| Gửi config JSON qua WS | POST `/connect` + SDP offer + config |
| Audio manual binary qua WS | WebRTC audio track tự động |
| Parse WS text messages | WebRTC data channel JSON events |

### ⚠️ LƯU Ý QUAN TRỌNG
Package `pipecat` trên pub.dev (v0.2.0) **KHÔNG DÙNG ĐƯỢC** — nó phụ thuộc vào Maven artifact `ai.pipecat:client:1.2.0` chưa tồn tại. Phải tự implement SmallWebRTC bằng `flutter_webrtc` + `http`.

---

## 2. GIAO THỨC SMALLWEBRTC (cần hiểu rõ)

### Signaling Flow
```
Flutter Client                         Pipecat Server (Python)
     |                                      |
     |  1. Tạo RTCPeerConnection            |
     |  2. getUserMedia (audio only)         |
     |  3. Tạo Data Channel                 |
     |  4. createOffer() → SDP offer        |
     |                                      |
     |-- HTTP POST /connect --------------→|  body: {sdp, type, config}
     |                                      |  Server tạo SmallWebRTCTransport
     |                                      |  Server setRemoteDescription(offer)
     |                                      |  Server createAnswer()
     |←-- HTTP 200 -----------------------|  body: {sdp, type}
     |                                      |
     |  5. setRemoteDescription(answer)     |
     |                                      |
     |====== WebRTC Connection OK ==========|
     |                                      |
     |-- Audio Track (mic) ===============→|  STT xử lý
     |←= Audio Track (TTS) ===============|  Bot phát audio
     |←= Data Channel (JSON) =============|  Transcripts, events
     |== Data Channel (JSON) =============→|  Text messages, commands
```

### Body POST `/connect` gửi đến server
```json
{
  "sdp": "v=0\r\no=- ...",     // SDP offer string
  "type": "offer",              // Luôn là "offer"
  "config": {                   // Config từ Flutter app
    "mode": "gemini_live",
    "google_api_key": "...",
    "model": "gemini-2.0-flash-live-001",
    "voice": "Aoede",
    "prompt": "You are a helpful translator..."
  }
}
```

### Server trả về
```json
{
  "sdp": "v=0\r\no=- ...",     // SDP answer string
  "type": "answer"
}
```

### Data Channel Messages (Server → Client)
```json
// User transcript
{"type": "transcript", "data": {"text": "Hello", "speaker": "user", "is_final": true}}

// Bot transcript
{"type": "bot_transcript", "data": {"text": "Xin chào"}}

// Bot output
{"type": "bot_output", "data": {"text": "Translated text"}}

// LLM text (instant)
{"type": "llm_text", "data": {"text": "..."}}

// Error
{"type": "error", "data": {"message": "..."}}

// Status
{"type": "connected", "data": {"status": "ok"}}
{"type": "bot_ready", "data": {}}
```

---

## 3. CÁC FILE CẦN SỬA

### 3.1. `pubspec.yaml` — Thêm dependency

```yaml
dependencies:
  # ... existing ...
  flutter_webrtc: ^1.4.1    # ← THÊM MỚI
  # http: ^1.3.0            # ← Đã có sẵn
```

> **KHÔNG** thêm `pipecat: ^0.2.0` — package này bị broken.

---

### 3.2. `lib/services/pipecat_service.dart` — VIẾT LẠI HOÀN TOÀN

```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/ai_translate_config.dart';

enum PipecatConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class PipecatTranscript {
  final String text;
  final String speaker;
  final String? timestamp;
  final bool isFinal;

  PipecatTranscript({
    required this.text,
    required this.speaker,
    this.timestamp,
    this.isFinal = true,
  });
}

class PipecatService {
  static final PipecatService _instance = PipecatService._();
  factory PipecatService() => _instance;
  PipecatService._();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  AiTranslateConfig? _config;

  final _connectionStateController =
      StreamController<PipecatConnectionState>.broadcast();
  final _transcriptController = StreamController<PipecatTranscript>.broadcast();
  final _botOutputController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  Stream<PipecatConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<PipecatTranscript> get transcripts => _transcriptController.stream;
  Stream<String> get botOutput => _botOutputController.stream;
  Stream<String> get errors => _errorController.stream;
  Stream<double> get audioLevel => _audioLevelController.stream;

  PipecatConnectionState _state = PipecatConnectionState.disconnected;
  PipecatConnectionState get currentState => _state;
  bool get isConnected => _state == PipecatConnectionState.connected;

  // ────────────────────────────────────────────────────────
  // Connect
  // ────────────────────────────────────────────────────────
  Future<void> connect(AiTranslateConfig config) async {
    if (_state == PipecatConnectionState.connecting ||
        _state == PipecatConnectionState.connected) {
      return;
    }

    _config = config;
    _updateState(PipecatConnectionState.connecting);

    try {
      // 1. Tạo PeerConnection
      final iceConfig = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ]
      };

      _pc = await createPeerConnection(iceConfig);

      // 2. Lấy local audio stream (mic only)
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      // Add audio track to peer connection
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      // 3. Tạo Data Channel cho events
      _dataChannel = await _pc!.createDataChannel(
        'events',
        RTCDataChannelInit()..ordered = true,
      );
      _setupDataChannel(_dataChannel!);

      // 4. Listen for remote audio track (TTS output)
      _pc!.onTrack = (RTCTrackEvent event) {
        debugPrint('PipecatService: Remote track received: ${event.track.kind}');
        // Audio track sẽ tự phát qua speaker
      };

      // 5. Connection state monitoring
      _pc!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('PipecatService: Connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _updateState(PipecatConnectionState.connected);
        } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                   state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _updateState(PipecatConnectionState.disconnected);
        }
      };

      _pc!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('PipecatService: ICE state: $state');
      };

      // 6. Tạo SDP Offer
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(offer);

      // 7. Đợi ICE gathering hoàn tất (hoặc timeout)
      await _waitForIceGathering();

      // 8. Lấy final SDP (bao gồm ICE candidates)
      final localDesc = await _pc!.getLocalDescription();

      // 9. POST SDP offer + config đến server
      final connectUrl = config.buildConnectUrl();
      debugPrint('PipecatService: POST $connectUrl');

      final response = await http.post(
        Uri.parse(connectUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sdp': localDesc!.sdp,
          'type': localDesc.type,
          'config': config.toServerParams(),
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Server error: ${response.statusCode} - ${response.body}');
      }

      final answerData = jsonDecode(response.body);

      // 10. Set remote description (server's answer)
      final answer = RTCSessionDescription(
        answerData['sdp'],
        answerData['type'],
      );
      await _pc!.setRemoteDescription(answer);

      debugPrint('PipecatService: WebRTC handshake complete');
      // Connection state sẽ update qua onConnectionState callback

    } catch (e) {
      debugPrint('PipecatService: Connection error: $e');
      _updateState(PipecatConnectionState.error);
      _errorController.add('Connection failed: $e');
      await _cleanup();
    }
  }

  // ────────────────────────────────────────────────────────
  // ICE Gathering
  // ────────────────────────────────────────────────────────
  Future<void> _waitForIceGathering() async {
    final completer = Completer<void>();

    // Timeout after 5 seconds
    Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) completer.complete();
    });

    _pc!.onIceGatheringState = (RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };

    await completer.future;
  }

  // ────────────────────────────────────────────────────────
  // Data Channel — nhận events từ server
  // ────────────────────────────────────────────────────────
  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (RTCDataChannelMessage message) {
      try {
        if (message.isBinary) return;
        final data = jsonDecode(message.text);
        _handleServerMessage(data);
      } catch (e) {
        debugPrint('PipecatService: Data channel parse error: $e');
      }
    };

    channel.onDataChannelState = (RTCDataChannelState state) {
      debugPrint('PipecatService: Data channel state: $state');
    };
  }

  void _handleServerMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final payload = data['data'];

    switch (type) {
      case 'transcript':
        final text = payload['text'] as String? ?? '';
        final speaker = payload['speaker'] as String? ?? 'user';
        final isFinal = payload['is_final'] as bool? ?? true;
        final timestamp = payload['timestamp'] as String?;
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(
            text: text, speaker: speaker, timestamp: timestamp, isFinal: isFinal,
          ));
        }
        break;

      case 'bot_output':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) _botOutputController.add(text);
        break;

      case 'bot_transcript':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(text: text, speaker: 'bot'));
        }
        break;

      case 'user_transcript':
        final text = payload['text'] as String? ?? '';
        final userId = payload['user_id'] as String?;
        final isFinal = payload['is_final'] as bool? ?? true;
        final timestamp = payload['timestamp'] as String?;
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(
            text: text,
            speaker: userId != null ? 'user ($userId)' : 'user',
            timestamp: timestamp, isFinal: isFinal,
          ));
        }
        break;

      case 'llm_text':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty && _config?.instantResponse == true) {
          _transcriptController.add(PipecatTranscript(text: text, speaker: 'llm'));
        }
        break;

      case 'error':
        final message = payload['message'] as String? ?? 'Unknown error';
        _errorController.add(message);
        break;

      case 'connected':
        debugPrint('PipecatService: Server confirmed connection');
        break;

      case 'bot_ready':
        debugPrint('PipecatService: Bot is ready');
        break;

      case 'speaking':
        final speaker = payload['speaker'] as String?;
        final isSpeaking = payload['is_speaking'] as bool? ?? false;
        debugPrint('PipecatService: $speaker ${isSpeaking ? "started" : "stopped"} speaking');
        break;

      default:
        debugPrint('PipecatService: Unknown message type: $type');
    }
  }

  // ────────────────────────────────────────────────────────
  // Mic control
  // ────────────────────────────────────────────────────────
  void setMicEnabled(bool enabled) {
    final audioTracks = _localStream?.getAudioTracks();
    if (audioTracks != null) {
      for (final track in audioTracks) {
        track.enabled = enabled;
      }
    }
  }

  // ────────────────────────────────────────────────────────
  // Send text via data channel
  // ────────────────────────────────────────────────────────
  void sendTextMessage(String text) {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
      'type': 'text',
      'data': {'text': text},
    })));
  }

  // ────────────────────────────────────────────────────────
  // Disconnect & Cleanup
  // ────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    await _cleanup();
    _updateState(PipecatConnectionState.disconnected);
  }

  Future<void> _cleanup() async {
    try {
      _dataChannel?.close();
      _dataChannel = null;

      _localStream?.getTracks().forEach((track) => track.stop());
      await _localStream?.dispose();
      _localStream = null;

      await _pc?.close();
      _pc = null;
    } catch (e) {
      debugPrint('PipecatService: Cleanup error: $e');
    }
  }

  void _updateState(PipecatConnectionState state) {
    _state = state;
    _connectionStateController.add(state);
  }

  void dispose() {
    disconnect();
    _connectionStateController.close();
    _transcriptController.close();
    _botOutputController.close();
    _errorController.close();
    _audioLevelController.close();
  }
}
```

---

### 3.3. `lib/models/ai_translate_config.dart` — Thêm method

Thêm sau `toServerParams()` (khoảng dòng 166):

```dart
/// Build URL cho SmallWebRTC signaling endpoint
String buildConnectUrl() {
  String url = serverUrl.trim();
  if (!url.endsWith('/connect')) {
    url = '$url/connect';
  }
  return url;
}
```

---

### 3.4. `lib/screens/ai_translate_screen.dart` — Sửa nhỏ

Chỉ sửa method `_toggleMic()` (dòng ~127):

```dart
// Trước:
void _toggleMic() {
  setState(() => _isMicEnabled = !_isMicEnabled);
}

// Sau:
void _toggleMic() {
  setState(() => _isMicEnabled = !_isMicEnabled);
  _pipecatService.setMicEnabled(_isMicEnabled);
}
```

---

### 3.5. Android Manifest — Thêm permissions (nếu chưa có)

File: `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.BLUETOOTH"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
```

---

## 4. PYTHON SERVER — KHÔNG CẦN SỬA

Server Python user cung cấp **đã phù hợp**:
- Endpoint: `POST /connect`
- Nhận: `{sdp, type, config}`
- Trả: `{sdp, type}` (answer)
- Transport: `SmallWebRTCTransport`
- Pipeline chạy background via `asyncio.create_task()`

```python
@app.post("/connect")
async def connect_endpoint(request: Request):
    data = await request.json()
    config = data.get("config", {})
    offer = data.get("sdp")
    answer = await start_pipecat_session(config, offer)
    return {"sdp": answer["sdp"], "type": answer["type"]}
```

---

## 5. THỨ TỰ THỰC HIỆN (checklist cho AI tiếp theo)

```
1. [ ] Kiểm tra android/app/src/main/AndroidManifest.xml có permissions WebRTC
2. [ ] Thêm flutter_webrtc: ^1.4.1 vào pubspec.yaml
3. [ ] Chạy: flutter pub get
4. [ ] Thay thế hoàn toàn lib/services/pipecat_service.dart (code mục 3.2)
5. [ ] Thêm buildConnectUrl() vào lib/models/ai_translate_config.dart (code mục 3.3)
6. [ ] Sửa _toggleMic() trong lib/screens/ai_translate_screen.dart (code mục 3.4)
7. [ ] Chạy: flutter analyze → fix lỗi
8. [ ] Test build: flutter build apk --debug
9. [ ] Test kết nối: chạy app → AI Translate → nhập URL → KẾT NỐI
```

---

## 6. THAM KHẢO API

### flutter_webrtc API chính (Dart)
```dart
// Tạo peer connection
final pc = await createPeerConnection(iceConfig);

// Lấy local audio
final stream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
pc.addTrack(track, stream);

// Data channel
final dc = await pc.createDataChannel('events', RTCDataChannelInit());
dc.onMessage = (msg) { ... };
dc.send(RTCDataChannelMessage(jsonString));

// SDP negotiation
final offer = await pc.createOffer({'offerToReceiveAudio': true});
await pc.setLocalDescription(offer);
await pc.setRemoteDescription(RTCSessionDescription(sdp, type));

// Remote audio
pc.onTrack = (event) { /* audio tự phát */ };

// Mic control
track.enabled = true/false;

// Cleanup
pc.close();
stream.dispose();
```

### SmallWebRTC Signaling Format
```
POST /connect
Content-Type: application/json

{
  "sdp": "<SDP offer string>",
  "type": "offer",
  "config": { ... app config ... }
}

Response 200:
{
  "sdp": "<SDP answer string>",
  "type": "answer"
}
```

---

## 7. LƯU Ý ĐẶC BIỆT

1. **KHÔNG dùng package `pipecat` trên pub.dev** — Maven dependency broken
2. **flutter_webrtc** tự phát remote audio qua speaker — không cần AudioPlayer
3. **ICE gathering** — Cần đợi ICE candidates gather xong trước khi POST offer (hoặc dùng trickle ICE)
4. **Data channel** — Server Pipecat SmallWebRTC tự tạo data channel phía server. Client tạo 1 data channel tên `events`. Cần verify tên channel phù hợp với server.
5. **CORS** — Server đã có CORS middleware cho phép tất cả origins
6. **Singleton pattern** — `PipecatService` dùng singleton, cleanup kỹ khi disconnect
7. **Config truyền kèm SDP** — Config gửi trong body POST cùng SDP offer, server parse từ `data.get("config")`

---

## 8. FILES ĐÃ SỬA (tóm tắt)

| File | Trạng thái | Ghi chú |
|---|---|---|
| `android/app/src/main/AndroidManifest.xml` | ✅ Đã sửa | +MODIFY_AUDIO_SETTINGS, BLUETOOTH, BLUETOOTH_CONNECT |
| `pubspec.yaml` | ✅ Đã sửa | +flutter_webrtc: ^1.4.1 |
| `lib/services/pipecat_service.dart` | ✅ Viết lại | WebSocket → WebRTC (RTCPeerConnection + DataChannel) |
| `lib/models/ai_translate_config.dart` | ✅ Đã sửa | +buildConnectUrl() method |
| `lib/screens/ai_translate_screen.dart` | ✅ Đã sửa | _toggleMic() gọi setMicEnabled() |
| `ws_server_fixed.py` | ✅ Tạo mới | Server Python dùng SmallWebRTCConnection API mới |

---

## 9. SERVER CẦN DEPLOY LÊN VPS

File `ws_server_fixed.py` đã có sẵn trong project. Nội dung chính:
- Dùng `SmallWebRTCConnection` + `webrtc_connection.initialize()` (API mới)
- ICE servers: STUN Google + TURN OpenRelay port 80 TCP
- Có logging ICE candidates
- Endpoint: `POST /connect`

Khi deploy nhớ:
1. Cài: `pip install "pipecat-ai[webrtc]" fastapi uvicorn google-generativeai`
2. Mở Security Group: UDP 49152-65535 inbound
3. Test: `python test_stun.py` → phải thấy `srflx` candidate
4. Chạy: `python ws_server.py` (port 3000)

---

## 10. TEST SCRIPTS ĐÃ TẠO

| File | Mục đích |
|---|---|
| `test_stun.py` | Test STUN candidate gathering |
| `test_turn.py` | Test TURN UDP port 3478 |
| `test_turn2.py` | Test TURN TCP port 80 |
| `test_turn3.py` | Test TURN UDP 3478 + 80 |
| `test_turn4.py` | Test TURN numb.viagenie.ca |
| `test_udp.py` | Test UDP connectivity cơ bản |
| `test_connectivity.py` | Test TCP/UDP connectivity tổng quát |

---

## 11. TRIỂN KHAI TRÊN VPS — TURN OVER TCP (Cập nhật 2026-05-09)

### Tình trạng VPS
- **Nhà cung cấp**: VPS Windows (không hỗ trợ UDP)
- **Phản hồi từ nhà cung cấp**: "Dịch vụ VPS tiêu chuẩn không hỗ trợ lưu lượng giao thức UDP"
- **Giải pháp**: Dùng TURN over TCP (pion/turn server)

### Security Group đã config (bởi nhà cung cấp)
| Port | Protocol | Status |
|------|----------|--------|
| 3478 | TCP | ✅ Đã mở |
| 3000 | TCP | ✅ Đã mở |

### Windows Firewall đã config (tự chạy)
```
netsh advfirewall firewall add rule name="STUN-TURN-3478-UDP" dir=in action=allow protocol=UDP localport=3478
netsh advfirewall firewall add rule name="STUN-TURN-3478-TCP" dir=in action=allow protocol=TCP localport=3478
netsh advfirewall firewall add rule name="WebRTC-Relay-UDP" dir=in action=allow protocol=UDP localport=49152-65535
netsh advfirewall firewall add rule name="Pipecat-Server-3000" dir=in action=allow protocol=TCP localport=3000
New-NetFirewallRule -DisplayName "WebRTC UDP" -Direction Inbound -Protocol UDP -LocalPort 49152-65535 -Action Allow
```

### TURN Server: pion/turn (thay vì coturn)
- **Lý do**: coturn không chạy native trên Windows
- **Chọn**: pion/turn (Go binary, chạy native Windows)

### Đang thực hiện — Bước cài đặt pion/turn

**Bước 1: Build binary trên laptop local**
```powershell
# Cài Go
winget install GoLang.Go

# Build turn-server
$env:GOOS = "windows"
$env:GOARCH = "amd64"
go install github.com/pion/turn/v4/cmd/turn-server@latest

# File output: C:\Users\<username>\go\bin\turn-server.exe
```

**Bước 2: Copy binary lên VPS**
```powershell
# Cách 1: SCP
scp "$env:GOPATH\bin\turn-server.exe" username@YOUR_VPS_IP:C:\turn-server\turn-server.exe

# Cách 2: RDP kéo thả
```

**Bước 3: Tạo config trên VPS (C:\turn-server\config.yaml)**
```yaml
[turn]
public-ip = YOUR_VPS_IP
realm = myserver
listening-port = 3478
user = test:test123
```

**Bước 4: Chạy TURN server trên VPS**
```powershell
cd C:\turn-server
.\turn-server.exe --config config.yaml
```

**Bước 5: Kiểm tra**
```powershell
netstat -an | findstr "3478"
# Phải thấy: TCP 0.0.0.0:3478 LISTENING
```

### Bước tiếp theo (sau khi TURN server chạy OK)
1. Cập nhật `ws_server.py` — đổi ICE servers dùng TURN local (`turn:YOUR_VPS_IP:3478`)
2. Cài dependencies Python: `pip install "pipecat-ai[webrtc]" fastapi uvicorn google-generativeai`
3. Chạy Pipecat server: `python ws_server.py`
4. Test kết nối từ Flutter app

### Config TURN server trong Python (sẽ cập nhật)
```python
# Trong ws_server.py, đổi ICE servers:
ice_servers = [
    {"urls": "stun:YOUR_VPS_IP:3478"},
    {
        "urls": "turn:YOUR_VPS_IP:3478",
        "username": "test",
        "credential": "test123"
    }
]
```

### ✅ TURN SERVER ĐÃ CHẠY (Cập nhật 2026-05-09)

**Binary**: `C:\turn-server\turn-server.exe` (pion/turn v5, build từ source `examples/turn-server/tcp`)

**Chạy trên VPS**:
```powershell
.\turn-server.exe --public-ip 103.118.29.243 --port 3478 --users "test=test123" --realm "myserver"
```

**Kết quả**:
- TCP 0.0.0.0:3478 LISTENING ✅
- Process turn-server đang chạy (PID 7256)

**Config cho Pipecat server**:
```python
ice_servers = [
    {"urls": "stun:103.118.29.243:3478"},
    {
        "urls": "turn:103.118.29.243:3478?transport=tcp",
        "username": "test",
        "credential": "test123"
    }
]
```

### ✅ PIPECAT SERVER ĐÃ CHẠY (Cập nhật 2026-05-09)

**Trên VPS** (`C:\Project\pipecat-main\ws_server.py`):
- Pipecat 1.1.0, Python 3.12.10
- Uvicorn running on `http://0.0.0.0:3000`
- ICE Servers: TURN local `103.118.29.243:3478` (TCP)

**Cả 2 service đang chạy trên VPS**:
1. TURN server: `turn-server.exe` (TCP 3478) — PID 7256
2. Pipecat server: `python ws_server.py` (TCP 3000) — PID 10476

**Flutter app config**:
- Server URL: `http://103.118.29.243:3000`

**Test kết quả (2026-05-09 11:28)**:
- `Test-NetConnection 103.118.29.243:3000` → TcpTestSucceeded: True ✅
- `curl http://103.118.29.243:3000/health` → `{"status":"healthy"}` ✅
- Flutter app kết nối → ICE FAILED ❌

### ❌ TURN OVER TCP THẤT BẠI (2026-05-09)

**Nguyên nhân**: TURN server tạo UDP relay (port 51157, 51158), nhưng VPS block UDP.

**Log chi tiết**:
```
SDP answer: a=candidate:... 1 udp ... 103.118.29.243 51157 typ host
SDP answer: a=candidate:... 1 udp ... 103.118.29.243 51158 typ relay
→ ICE check FAILED (timeout 60s)
```

**Kết luận**: Giải pháp 1 (TURN over TCP) KHÔNG khả thi.
- TURN server lắng nghe TCP 3478 ✅
- Nhưng relay allocation vẫn dùng UDP ❌
- WebRTC media bắt buộc cần UDP → không thể chạy trên VPS không hỗ trợ UDP

**Giải pháp còn lại**: Đổi VPS sang nhà cung cấp hỗ trợ UDP (DigitalOcean/Vultr/Hetzner)

---

## 12. MIGRATE SANG ORACLE CLOUD FREE (Cập nhật 2026-05-09)

### Bước 1: Tạo tài khoản Oracle Cloud
1. Vào https://cloud.oracle.com/free
2. Nhấn **Start for free**
3. Đăng ký (cần thẻ tín dụng/debit để verify, KHÔNG bị trừ tiền)
4. Chọn region gần nhất (gợi ý: **Singapore** hoặc **Tokyo** cho Việt Nam)

### Bước 2: Tạo VM Instance
1. Menu → **Compute** → **Instances** → **Create Instance**
2. Config:
   - **Name**: `pipecat-server`
   - **Image**: `Ubuntu 22.04 Minimal` (hoặc 24.04)
   - **Shape**: `VM.Standard.E2.1.Micro` (Always Free - 1GB RAM, 1 OCPU)
   - **Networking**: Tạo VCN mới (mặc định)
   - **SSH Keys**: Tạo key pair mới → tải private key về
3. Nhấn **Create**

### Bước 3: Mở Ports (Security Rules)
1. Menu → **Networking** → **Virtual Cloud Networks** → chọn VCN đã tạo
2. Nhấn vào **Subnet** → **Default Security List**
3. Nhấn **Add Ingress Rules**:

| # | Source | Protocol | Dest Port | Mục đích |
|---|--------|----------|-----------|----------|
| 1 | 0.0.0.0/0 | TCP | 3478 | TURN server |
| 2 | 0.0.0.0/0 | UDP | 3478 | TURN server |
| 3 | 0.0.0.0/0 | TCP | 3000 | Pipecat server |
| 4 | 0.0.0.0/0 | UDP | 49152-65535 | WebRTC media |

### Bước 4: SSH vào VM
```powershell
ssh -i "path/to/private-key.pem" ubuntu@<VM_PUBLIC_IP>
```

### Bước 5: Cài đặt trên VM (Ubuntu)

**5.1 Cài Python + dependencies**:
```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git

# Tạo virtual environment
python3 -m venv ~/pipecat-env
source ~/pipecat-env/bin/activate

# Cài Pipecat
pip install "pipecat-ai[webrtc]" fastapi uvicorn google-generativeai
```

**5.2 Cài coturn (TURN server)**:
```bash
sudo apt install -y coturn

# Bật coturn
sudo systemctl stop coturn
sudo sed -i 's/#TURNSERVER=1/TURNSERVER=1/' /etc/default/coturn
```

**5.3 Config coturn**:
```bash
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
```

**5.4 Start coturn**:
```bash
sudo systemctl start coturn
sudo systemctl enable coturn
sudo systemctl status coturn
```

**5.5 Copy Pipecat server**:
```bash
# Upload ws_server.py lên VM (dùng SCP từ laptop)
scp -i "path/to/private-key.pem" ws_server_fixed.py ubuntu@<VM_IP>:~/pipecat-server/ws_server.py
```

**5.6 Chạy Pipecat server**:
```bash
cd ~/pipecat-server
source ~/pipecat-env/bin/activate
python ws_server.py
```

### Bước 6: Cập nhật ICE servers trong ws_server.py
```python
# Thay YOUR_VM_IP bằng IP thực của VM Oracle
ICE_SERVERS = [
    IceServer(urls="stun:YOUR_VM_IP:3478"),
    IceServer(
        urls="turn:YOUR_VM_IP:3478",
        username="test",
        credential="test123",
    ),
]
```

### Bước 7: Test
```bash
# Trên laptop
Test-NetConnection -ComputerName YOUR_VM_IP -Port 3478
Test-NetConnection -ComputerName YOUR_VM_IP -Port 3000
curl http://YOUR_VM_IP:3000/health -UseBasicParsing
```

### Bước 8: Flutter app
- Server URL: `http://YOUR_VM_IP:3000`

### Lưu ý Oracle Cloud
- Always Free: VM.Standard.E2.1.Micro (1GB RAM, 1 OCPU) — MIỄN PHÍ vĩnh viễn
- 10GB storage, 10TB outbound/tháng
- Cần mở ports trong Security Rules (không phải iptables)
- Nếu dùng Ubuntu, có thể cần mở port bằng iptables:
```bash
sudo iptables -I INPUT -p tcp --dport 3478 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 3478 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 49152:65535 -j ACCEPT
```

---

## 13. FREE TURN SERVICE — TWILIO (Cập nhật 2026-05-09)

### Quyết định
Dùng **Twilio TURN** (10GB free/tháng) thay vì đổi VPS.
- VPS hiện tại chỉ cần TCP 3000 cho Pipecat server
- TURN server chạy trên Twilio (hỗ trợ UDP/TCP)
- Media flow: Client → Twilio TURN → VPS

### Bước 1: Tạo tài khoản Twilio
1. Vào https://www.twilio.com/en-us/try-twilio
2. Đăng ký (Google/GitHub)
3. Verify email + số điện thoại

### Bước 2: Lấy TURN Credentials
1. Login https://console.twilio.com
2. Menu → Account → API keys & tokens
3. Hoặc: https://console.twilio.com/us1/develop/relay-credentials
4. Tạo Credential → NAT Traversal → TURN
5. Lưu: Account SID, API Key SID, API Key Secret

### Bước 3: Tạo TURN Token
```powershell
curl -X POST "https://accounts.twilio.com/v1/Accounts/YOUR_ACCOUNT_SID/Tokens" `
  -u "YOUR_API_KEY_SID:YOUR_API_KEY_SECRET" `
  -H "Content-Type: application/x-www-form-urlencoded"
```

### Bước 4: Cập nhật ws_server.py
```python
ICE_SERVERS = [
    IceServer(urls="stun:global.stun.twilio.com:3478?transport=udp"),
    IceServer(
        urls="turn:global.turn.twilio.com:3478?transport=udp",
        username="TWILIO_USERNAME",
        credential="TWILIO_CREDENTIAL",
    ),
    IceServer(
        urls="turn:global.turn.twilio.com:3478?transport=tcp",
        username="TWILIO_USERNAME",
        credential="TWILIO_CREDENTIAL",
    ),
]
```

### Bước 5: Test
- Server URL: `http://103.118.29.243:3000` (VPS hiện tại)
- TURN: Twilio (UDP + TCP)

### Twilio TURN Credentials (đã tạo 2026-05-09)
```
Account SID: AC842a51114f6bfe562097cf1abcf0220f
Username: 01dcf15dd91338c8a372763a39caeec3a89ca541a4261064a8b2518e878dbc30
Credential: LtlLcrmeBVH2JssPth2mix1scsaeoy/N1G8Y6Qknc18=
```

ICE Servers config:
```python
ICE_SERVERS = [
    IceServer(urls="stun:global.stun.twilio.com:3478"),
    IceServer(
        urls="turn:global.turn.twilio.com:3478?transport=udp",
        username="01dcf15dd91338c8a372763a39caeec3a89ca541a4261064a8b2518e878dbc30",
        credential="LtlLcrmeBVH2JssPth2mix1scsaeoy/N1G8Y6Qknc18=",
    ),
    IceServer(
        urls="turn:global.turn.twilio.com:3478?transport=tcp",
        username="01dcf15dd91338c8a372763a39caeec3a89ca541a4261064a8b2518e878dbc30",
        credential="LtlLcrmeBVH2JssPth2mix1scsaeoy/N1G8Y6Qknc18=",
    ),
]
```

### Lưu ý Twilio
- Free: 10GB TURN traffic/tháng
- TURN credentials có thời hạn (mỗi lần gọi API tạo token mới)
- Cần regenerate token trước khi hết hạn (hoặc dùng tự động)
- Twilio TURN hỗ trợ cả UDP và TCP → WebRTC media hoạt động bình thường

### ❌ TWILIO TURN CŨNG THẤT BẠI (2026-05-09)

**Nguyên nhân**: aiortc/aioice chỉ tạo UDP relay, không hỗ trợ TCP relay.

**Phân tích source code**:
- `connection_kwargs()`: Chỉ dùng 1 TURN server đầu tiên
- `relayed_candidate()`: Luôn tạo `transport="udp"` cho relay candidate
- Dù kết nối TURN qua TCP (`transport=tcp`), relay allocation vẫn tạo UDP port

**Kết quả test**:
- `transport=udp` → Không kết nối được TURN (VPS block UDP)
- `transport=tcp` → Kết nối TURN OK, nhưng relay tạo UDP port → VPS block UDP → ICE failed

**Kết luận cuối cùng**: WebRTC BẮT BUỘC cần UDP. Không có giải pháp nào hoạt động trên VPS không hỗ trợ UDP.

**Giải pháp duy nhất**: Đổi VPS hỗ trợ UDP (Oracle Cloud Free / DigitalOcean / Vultr / Hetzner)

### Lưu ý quan trọng
- VPS **khỗng hỗ trợ UDP** → tất cả media đi qua TCP
- Hiệu năng sẽ chậm hơn UDP (độ trễ cao hơn)
- Nếu không đủ, cần đổi nhà cung cấp VPS (DigitalOcean/Vultr/Hetzner đều hỗ trợ UDP)
