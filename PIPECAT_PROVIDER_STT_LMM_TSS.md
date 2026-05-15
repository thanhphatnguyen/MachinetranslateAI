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
