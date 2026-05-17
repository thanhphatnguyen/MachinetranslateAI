# Pipecat Provider: STT / LLM / TTS

## Piper TTS

### Cài đặt
```bash
pip install piper-tts
# hoặc
pip install "pipecat-ai[piper]"
```

### Sử dụng (pipecat 0.0.108)
```python
from pipecat.services.piper.tts import PiperTTSService

# Cách mới (khuyến nghị)
tts = PiperTTSService(settings=PiperTTSService.Settings(voice="vi_VN-vivos-x_low"))

# Cách cũ (deprecated, có warning)
tts = PiperTTSService(voice_id="vi_VN-vivos-x_low")
```

### Lưu ý quan trọng
- **Không dùng** `model=` param → sẽ lỗi `'NoneType' object has no attribute 'strip'`
- Piper tự động tải model `.onnx` lần đầu nếu chưa có
- SSL error khi download model → thêm `ssl._create_default_https_context = ssl._create_unverified_context`

### Models phổ biến
| Model | Ngôn ngữ | Giọng |
|-------|----------|-------|
| `vi_VN-vivos-x_low` | Vietnamese | Nam (low quality) |
| `vi_VN-vivos-x_medium` | Vietnamese | Nam (medium) |
| `en_US-lessac-medium` | English | Nữ |
| `en_US-ryan-high` | English | Nam |

---

## Soniox STT

### SonioxRealtimeTranslationSTT (Custom Processor)

Đây là custom `FrameProcessor` kết nối trực tiếp Soniox WebSocket API để dịch realtime.

**Đặc điểm:**
- Kết nối `wss://stt-rt.soniox.com/transcribe-websocket`
- Gửi audio PCM 16kHz mono trực tiếp lên WebSocket
- Nhận token dịch thuật, gom thành câu, đẩy `TextFrame` cho TTS
- Hỗ trợ `one_way` và `two_way` translation
- Hỗ trợ `soniox_context` (từ vựng chuyên ngành)

**Constructor:**
```python
SonioxRealtimeTranslationSTT(
    api_key="...",
    translate_type="one_way",  # hoặc "two_way"
    lang_a="en",               # ngôn ngữ nguồn
    lang_b="vi",               # ngôn ngữ đích
    enable_diarization=False,
    extra_context={...},       # soniox context
    on_translation=callback    # callback(text, speaker, source_text)
)
```

**Config gửi lên Soniox:**
```python
{
    "api_key": "...",
    "model": "stt-rt-v4",
    "audio_format": "pcm_s16le",
    "sample_rate": 16000,
    "num_channels": 1,
    "enable_endpoint_detection": True,
    "language_hints": ["en", "vi"],
    "enable_language_identification": True,  # two_way
    "enable_speaker_diarization": False,
    "translation": {
        "type": "one_way",
        "target_language": "vi"
    },
    "context": {  # optional
        "general": [{"key": "domain", "value": "Healthcare"}],
        "terms": ["Insulin", "Celebrex"],
        "translation_terms": [{"source": "stroke", "target": "đột quỵ"}]
    }
}
```

### Soniox Token Structure
```python
{
    "tokens": [
        {
            "text": "Xin",
            "is_final": False,
            "translation_status": "translation"  # hoặc "" cho source
        }
    ]
}
```
- `translation_status == "translation"` → token bản dịch
- `translation_status != "translation"` → token nguồn (user speech)

### Cách gom token thành câu
- **Translation tokens**: gom vào buffer, flush khi gặp dấu câu (`.`, `!`, `?`)
- **Source tokens**: gom vào buffer, flush sau 1.5s im lặng (timer-based)

---

## Pipecat 0.0.108 Lifecycle Notes

### FrameProcessor lifecycle
```python
class CustomProcessor(FrameProcessor):
    async def process_frame(self, frame, direction):
        # PHẢI gọi super() trước để set __started = True
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            # Setup ở đây
            pass
        elif isinstance(frame, AudioRawFrame):
            # Xử lý audio
            pass
        elif isinstance(frame, (EndFrame, CancelFrame)):
            # Cleanup
            pass

        # Phải gọi push_frame() cuối cùng để truyền frame downstream
        await self.push_frame(frame, direction)
```

### Lưu ý quan trọng
- **Phải gọi `super().process_frame()` TRƯỚC** khi xử lý frame
- Nếu không gọi `super()`, `__started` sẽ là False → `push_frame` bị ignore
- `StartFrame` là `SystemFrame` → được xử lý qua `__input_frame_task_handler`
- `websockets` mới bỏ attribute `.open` → dùng `try/except` thay vì `if ws.open`

### Imports cần thiết (pipecat 0.0.108)
```python
from pipecat.frames.frames import (
    LLMRunFrame, Frame, AudioRawFrame, TextFrame,
    StartFrame, EndFrame, CancelFrame, ErrorFrame
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
```

**Lưu ý:** `FrameDirection` nằm ở `pipecat.processors.frame_processor`, KHÔNG phải `pipecat.frames.frames`

---

## Data Channel (Transcript to Flutter)

### Gửi transcript qua WebRTC data channel
```python
# SmallWebRTCConnection có method send_app_message()
webrtc_connection.send_app_message({
    "type": "pro_translate",
    "data": {
        "speaker": "bot",
        "source": "How old are you?",
        "translation": "Bạn mấy tuổi?"
    }
})
```

### Flutter nhận message
```dart
// PipecatService._handleServerMessage()
case 'pro_translate':
    final speaker = payload['speaker'];
    final source = payload['source'];
    final translation = payload['translation'];
```

---

## Các lỗi thường gặp

| Lỗi | Nguyên nhân | Fix |
|-----|-------------|-----|
| `'NoneType' object has no attribute 'strip'` | Piper nhận `model=None` | Dùng `voice_id=` hoặc `settings=` |
| `ImportError: cannot import name 'FrameDirection'` | Import sai module | `from pipecat.processors.frame_processor import FrameDirection` |
| `'ClientConnection' object has no attribute 'open'` | websockets mới bỏ `.open` | Dùng `try/except` |
| `Trying to process StartFrame but StartFrame not received yet` | Chưa gọi `super().process_frame()` | Thêm `await super().process_frame(frame, direction)` đầu tiên |
| `SSL: CERTIFICATE_VERIFY_FAILED` | Python SSL cert error | `ssl._create_default_https_context = ssl._create_unverified_context` |
| `takes 2 positional arguments but 3 were given` | Lambda/callback sai số args | Đảm bảo callback đúng số params |

---

## Pro Translate Config (Flutter → Server)

```json
{
    "mode": "pro_translate",
    "source_language": "en",
    "target_language": "vi",
    "translation_type": "two_way",
    "stt": {
        "api_key": "YOUR_SONIOX_KEY",
        "diarize": false
    },
    "tts": {
        "model": "vi_VN-vivos-x_low"
    },
    "soniox_context": {
        "general": [{"key": "domain", "value": "Healthcare"}],
        "terms": ["Insulin"],
        "translation_terms": [{"source": "stroke", "target": "đột quỵ"}]
    }
}
```

---

## STT Providers (create_stt factory)

| Provider | Class | Params |
|----------|-------|--------|
| deepgram | `DeepgramSTTService` | `api_key`, `diarize` |
| openai | `OpenAISTTService` | `api_key` |
| google | `GoogleSTTService` | `api_key` |
| assemblyai | `AssemblyAISTTService` | `api_key`, `speaker_labels` |
| soniox | `SonioxSTTService` | `api_key`, `enable_speaker_diarization`, `target_language`, `context` |
| groq | `GroqSTTService` | `api_key` |
| whisper | `WhisperSTTService` | `api_key` |

## TTS Providers (create_tts factory)

| Provider | Class | Params |
|----------|-------|--------|
| deepgram | `DeepgramTTSService` | `api_key` |
| openai | `OpenAITTSService` | `api_key` |
| google | `GoogleTTSService` | `api_key` |
| elevenlabs | `ElevenLabsTTSService` | `api_key` |
| cartesia | `CartesiaTTSService` | `api_key` |
| soniox | `SonioxTTSService` | `api_key` |
| piper | `PiperTTSService` | `voice_id` hoặc `settings` |

---

## Soniox Realtime Translation STT - Token Processing

### Token structure từ Soniox
```json
{
    "tokens": [
        {
            "text": "Hello",
            "is_final": true,
            "translation_status": "",
            "speaker": "1",
            "language": "en"
        },
        {
            "text": "Xin chào",
            "is_final": true,
            "translation_status": "translation"
        }
    ]
}
```

### REPLACE/APPEND logic với `_last_was_final` flag

Non-final tokens là bản mở rộng của cùng 1 token (VD: "H" → "Ho" → "Hom" → "Hôm"). Khi final đến, phải REPLACE non-final cũ, KHÔNG append.

| `_last_was_final` | Token mới | Hành động | Lý do |
|---|---|---|---|
| False | non-final | REPLACE last item | Token mở rộng (H→Ho→Hom) |
| False | final | REPLACE last item | Bản hoàn chỉnh thay bản nháp |
| True | non-final | APPEND | Token mới bắt đầu mở rộng |
| True | final | APPEND | Token mới hoàn chỉnh |

**SAI (endswith heuristic):** `"Hôm"` (non-final) → `"Hôm "` (final, endswith " ") → append → `["Hôm", "Hôm "]` ← duplicate!

**ĐÚNG (flag):** `"Hôm"` (non-final, _last=False) → `"Hôm "` (final, _last=False) → replace → `["Hôm "]` ✓

### `<end>` filter
Soniox gửi `{"text": "<end>"}` khi endpoint detection. Phải filter bỏ qua:
```python
if text.strip().lower() == "<end>":
    continue
```

### Speaker & Language capture
```python
# Source tokens
token_speaker = token.get("speaker", "")  # "1", "2", etc.
if token_speaker:
    self._current_speaker = token_speaker

token_lang = token.get("language", "")  # "en", "vi", etc.
if token_lang and self._language_router:
    if token_lang == self._lang_a:
        self._language_router.set_target_lang(self._lang_b)
```

---

## TTSService - Text Aggregation Modes

### SENTENCE mode (default)
- Buffer text until sentence boundary (punctuation)
- Flush trigger: `LLMFullResponseEndFrame`
- **VẤN ĐỀ:** TextFrame từ background task mà KHÔNG có LLMFullResponseEndFrame → text buffer vĩnh viễn, `run_tts()` không bao giờ gọi

### TOKEN mode
- Mỗi TextFrame trigger TTS ngay
- Phù hợp cho pipeline không phải LLM (VD: Pro Translate)

### Cách trigger TTS thủ công (từ background task)
```python
await self.push_frame(LLMFullResponseStartFrame())
await self.push_frame(TextFrame(text))
await self.push_frame(LLMFullResponseEndFrame())
```
`LLMFullResponseEndFrame` flush text aggregator → gọi `run_tts()`.

---

## LanguageRouter - Route TextFrame theo ngôn ngữ

Pipecat pipeline là linear (không branch). Để route TextFrame đến 2 TTS khác nhau:

```python
class LanguageRouter(FrameProcessor):
    def __init__(self, tts_a, source_lang, target_lang, tts_b=None):
        self._tts_a = tts_a
        self._tts_b = tts_b
        self._current_target_lang = target_lang

    async def process_frame(self, frame, direction):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            # SystemFrame: gửi cả 2 TTS để init
            await self._tts_a.process_frame(frame, direction)
            if self._tts_b:
                await self._tts_b.process_frame(frame, direction)
            await self.push_frame(frame, direction)

        elif isinstance(frame, TextFrame):
            # Route đến TTS đúng ngôn ngữ
            tts = self._get_active_tts()
            await tts.process_frame(frame, direction)

        else:
            await self.push_frame(frame, direction)
```

**Lưu ý:** `StartFrame` phải gửi đến TẤT CẢ TTS instances để init (set sample_rate, create audio context task). KHÔNG được skip.

---

## AudioRawFrame handling trong STT processor

Khi STT processor cần consume AudioRawFrame (gửi lên WebSocket) mà KHÔNG muốn push downstream:

```python
elif isinstance(frame, AudioRawFrame):
    if self._ws:
        await self._ws.send(frame.audio)
    pass  # KHÔNG gọi push_frame - "chìm" frame
```

Nếu push_frame → AudioRawFrame lọt xuống TTS → echo/feedback.

---

## Lỗi thường gặp (đã fix)

| Lỗi | Nguyên nhân | Fix |
|-----|-------------|-----|
| `NameError: name 'Frame' is not defined` | Type annotation `frame: Frame` trong pipecat 0.0.108 VPS | Bỏ type annotation: `process_frame(self, frame, direction)` |
| Piper không tạo audio | SENTENCE mode cần `LLMFullResponseEndFrame` để flush | Wrap TextFrame với Start/End frames |
| Source text duplicate ("đi Bạn ăn gì đi") | `endswith(" ")` heuristic sai khi non-final → final | Dùng `_last_was_final` flag |
| "Speaker X" không có dịch | Timer flush gửi user textộc lập | Timer chỉ clear buffer, chỉ gửi khi có translation |
| `<end>` hiển thị | Soniox endpoint detection token | Filter `text.strip().lower() == "<end>"` |
| Dropdown crash `items.where...` | Value không có trong items list | Thêm value vào danh sách items |
