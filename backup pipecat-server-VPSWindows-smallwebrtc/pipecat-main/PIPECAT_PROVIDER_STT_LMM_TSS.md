# PIPECAT PROVIDER - STT / LLM / TTS

> **Ngày tạo**: 2026-05-12
> **Mục đích**: Tài liệu tham chiếu cho các AI khác khi cần tích hợp provider
> **Trạng thái**: Cập nhật Soniox (từ Pipecat source code)

---

## SONIOX

**Website**: https://soniox.com
**Console**: https://console.soniox.com
**Docs**: https://soniox.com/docs
**GitHub**: https://github.com/soniox
**Discord**: https://discord.gg/rWfnk9uM5j
**API Status**: https://status.soniox.com

---

### 1. SONIOX STT (Speech-to-Text)

**Docs**: https://soniox.com/docs/stt/rt/real-time-transcription
**Pipecat Integration**: https://soniox.com/docs/integrations/pipecat/stt

#### Pipecat Usage

```python
import os
from pipecat.services.soniox.stt import SonioxSTTService

stt = SonioxSTTService(
    api_key=os.getenv("SONIOX_API_KEY"),
)
```

#### Constructor Arguments

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `api_key` | `str` | required | Soniox API key |
| `url` | `str` | `wss://stt-rt.soniox.com/transcribe-websocket` | WebSocket endpoint |
| `sample_rate` | `int | None` | `None` | Audio sample rate (Hz). None = inherit từ pipeline |
| `audio_format` | `str` | `pcm_s16le` | Audio format (init-only, không update runtime) |
| `num_channels` | `int` | `1` | Số kênh audio (init-only) |
| `vad_force_turn_endpoint` | `bool` | `True` | Pipecat VAD triggers finalization |
| `ttfs_p99_latency` | `float | None` | `0.35` | P99 latency (speech end → final transcript). Dùng cho turn stop strategies |
| `settings` | `Settings` | `None` | Runtime-configurable settings |

#### Settings (SonioxSTTSettings — runtime-updatable via STTUpdateSettingsFrame)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `model` | `str` | `stt-rt-v4` | Model identifier |
| `language` | `Language | str | None` | `None` | Primary language |
| `language_hints` | `list[Language]` | `None` | Bias toward expected languages |
| `language_hints_strict` | `bool` | `None` | Restrict to provided languages |
| `context` | `SonioxContextObject | str | None` | `None` | Custom vocabulary & domain. `str` cho context_version 1, `SonioxContextObject` cho v2+ |
| `enable_speaker_diarization` | `bool` | `False` | Speaker ID annotation |
| `enable_language_identification` | `bool` | `False` | Language ID annotation |
| `client_reference_id` | `str | None` | `None` | Client reference ID for tracking |

#### Regional Endpoints

| Region | URL |
|--------|-----|
| US (default) | `wss://stt-rt.soniox.com/transcribe-websocket` |
| EU | `wss://stt-rt.eu.soniox.com/transcribe-websocket` |

#### VAD Modes

- **Pipecat VAD (default)**: `vad_force_turn_endpoint=True` — Pipecat local VAD finalizes transcripts, lower latency
- **Soniox native**: `vad_force_turn_endpoint=False` — Soniox detects natural pauses

#### Language Hints Example

```python
from pipecat.services.soniox.stt import SonioxSTTService
from pipecat.transcriptions.language import Language

stt = SonioxSTTService(
    api_key=os.getenv("SONIOX_API_KEY"),
    settings=SonioxSTTService.Settings(
        language_hints=[Language.EN, Language.ES, Language.JA, Language.ZH],
    ),
)
```

#### Context Customization Example

```python
from pipecat.services.soniox.stt import (
    SonioxSTTService,
    SonioxContextObject,
    SonioxContextGeneralItem,
    SonioxContextTranslationTerm,
)

stt = SonioxSTTService(
    api_key=os.getenv("SONIOX_API_KEY"),
    settings=SonioxSTTService.Settings(
        context=SonioxContextObject(
            general=[
                SonioxContextGeneralItem(key="domain", value="Healthcare"),
                SonioxContextGeneralItem(key="topic", value="Diabetes consultation"),
            ],
            terms=["Celebrex", "Zyrtec", "Xanax"],
            translation_terms=[
                SonioxContextTranslationTerm(source="Mr. Smith", target="Sr. Smith"),
                SonioxContextTranslationTerm(source="stroke", target="ictus"),
            ],
        ),
    ),
)
```

#### SonioxContextObject (cho model stt-rt-v3-preview trở lên)

| Field | Type | Description |
|-------|------|-------------|
| `general` | `list[SonioxContextGeneralItem] | None` | Key-value pairs: domain, topic, doctor, patient, organization... |
| `text` | `str | None` | Free-text context (mô tả ngữ cảnh) |
| `terms` | `list[str] | None` | Custom thuật ngữ (tên thuốc, thuật ngữ chuyên ngành...) |
| `translation_terms` | `list[SonioxContextTranslationTerm] | None` | Custom translation mappings (source → target) |

#### STT Event Handlers

| Event | Description |
|-------|-------------|
| `on_connected` | Connected to Soniox STT service |
| `on_disconnected` | Disconnected from Soniox STT service |
| `on_connection_error` | Connection error occurred |

#### Latency Benchmark

- **P99 TTFS**: 0.35 giây (tương đương Deepgram)
- Được dùng bởi turn stop strategies để tối ưu thời gian xử lý

#### Runtime Settings Update

Có thể cập nhật settings giữa chừng qua `STTUpdateSettingsFrame`:
```python
from pipecat.frames.frames import STTUpdateSettingsFrame
# Thay đổi language runtime (trigger disconnect + reconnect)
await task.queue_frames([STTUpdateSettingsFrame(
    settings=SonioxSTTService.Settings(language=Language.ES)
)])
```

---

### 2. SONIOX STT - Real-time Translation

**Docs**: https://soniox.com/docs/stt/rt/real-time-translation

#### Tính năng

- **Mid-sentence translation**: Dịch ngay giữa câu, không đợi nói xong
- **One-way translation**: Dịch tất cả ngôn ngữ → 1 ngôn ngữ đích
- **Two-way translation**: Dịch qua lại giữa 2 ngôn ngữ
- **Unified token stream**: Transcription và translation cùng stream, có label phân biệt
- **Supported languages**: Tất cả cặp ngôn ngữ được hỗ trợ

#### Translation Modes

**One-way** (dịch tất cả → 1 ngôn ngữ đích):
```json
{
  "translation": {
    "type": "one_way",
    "target_language": "fr"
  }
}
```

**Two-way** (dịch qua lại 2 ngôn ngữ):
```json
{
  "translation": {
    "type": "two_way",
    "language_a": "ja",
    "language_b": "ko"
  }
}
```

#### Token Format

| Field | Description |
|-------|-------------|
| `text` | Token text |
| `translation_status` | `"none"` (not translated), `"original"` (spoken), `"translation"` (translated) |
| `language` | Language of token |
| `source_language` | Original language (only for translated tokens) |

#### Raw WebSocket Example (Python)

```python
import json
from websockets.sync.client import connect

SONIOX_WEBSOCKET_URL = "wss://stt-rt.soniox.com/transcribe-websocket"

config = {
    "api_key": "YOUR_API_KEY",
    "model": "stt-rt-v4",
    "language_hints": ["en", "vi"],
    "enable_language_identification": True,
    "enable_speaker_diarization": True,
    "enable_endpoint_detection": True,
    "translation": {
        "type": "two_way",
        "language_a": "en",
        "language_b": "vi"
    }
}

with connect(SONIOX_WEBSOCKET_URL) as ws:
    ws.send(json.dumps(config))
    # Stream audio bytes...
    # ws.send(audio_bytes)
    # ws.send("")  # End of audio
```

---

### 3. SONIOX TTS (Text-to-Speech)

**Docs**: https://soniox.com/docs/tts/get-started
**Pipecat Integration**: https://soniox.com/docs/integrations/pipecat/tts

#### Pipecat Usage

```python
import os
from pipecat.services.soniox.tts import SonioxTTSService

tts = SonioxTTSService(
    api_key=os.getenv("SONIOX_API_KEY"),
    settings=SonioxTTSService.Settings(
        voice="Adrian",
    ),
)
```

#### Constructor Arguments

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `api_key` | `str` | required | Soniox API key |
| `url` | `str` | `wss://tts-rt.soniox.com/tts-websocket` | WebSocket endpoint |
| `sample_rate` | `int | None` | `None` | Output sample rate: `{8000, 16000, 24000, 44100, 48000}`. None = inherit từ pipeline |
| `audio_format` | `str` | `pcm_s16le` | Output audio format (init-only) |
| `text_aggregation_mode` | `TextAggregationMode | None` | `None` | `SENTENCE` (default) or `TOKEN` (lower latency) |
| `settings` | `Settings` | `None` | Runtime-configurable settings |

#### Settings (SonioxTTSSettings — runtime-updatable via TTSUpdateSettingsFrame)

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `model` | `str` | `tts-rt-v1` | TTS model identifier |
| `voice` | `str` | `Adrian` | Voice identifier |
| `language` | `Language | str` | `Language.EN` | Language for synthesis |

#### Available Voices

| Voice | Notes |
|-------|-------|
| `Adrian` | Default voice |
| `Maya` | Used trong voice-soniox.py example |
| Xem thêm | https://soniox.com/docs/tts/concepts/voices |

#### Supported Languages (60+ ngôn ngữ)

```
af, ar, az, be, bg, bn, bs, ca, cs, cy, da, de, el, en, es, et, eu,
fa, fi, fr, gl, gu, he, hi, hr, hu, id, it, ja, kk, kn, ko, lt, lv,
mk, ml, mr, ms, nl, no, pa, pl, pt, ro, ru, sk, sl, sq, sr, sv, sw,
ta, te, th, tl, tr, uk, ur, vi, zh
```

**Có tiếng Việt (`vi`)** — dùng được cho dự án dịch thuật.

#### Multi-stream Multiplexing

- Tối đa **5 concurrent streams** trên 1 WebSocket connection
- Mỗi stream có `stream_id` riêng, config riêng (voice, model, language)
- Pipecat tự quản lý stream_id qua audio-context mechanism

#### Special Features

- **Streaming text-in, audio-out**: Text stream incrementally, audio trả về base64 chunks
- **Eager stream opening**: `on_turn_context_created` mở stream sẵn trước khi text đến
- **Runtime settings changes**: Đổi voice/model/language → flush stream hiện tại, tạo stream mới (không cần reconnect WebSocket)
- **Keepalive**: Gửi `{"keep_alive": true}` mỗi 20 giây (tránh Soniox idle timeout 20-30s)
- **Stream cancellation**: Khi bị interrupt, gửi `{"stream_id": ..., "cancel": true}` để dừng synthesis ngay

#### TTS Event Handlers

| Event | Description |
|-------|-------------|
| `on_connected` | Connected to Soniox TTS service |
| `on_disconnected` | Disconnected from Soniox TTS service |

#### Regional Endpoints

| Region | URL |
|--------|-----|
| US (default) | `wss://tts-rt.soniox.com/tts-websocket` |
| EU | `wss://tts-rt.eu.soniox.com/tts-websocket` |

#### Text Aggregation Modes

- **SENTENCE** (default): Buffer text until sentence boundaries, more natural speech
- **TOKEN**: Stream at token level, lower latency

#### Advanced Example

```python
from pipecat.services.soniox.tts import SonioxTTSService
from pipecat.services.tts_service import TextAggregationMode

tts = SonioxTTSService(
    api_key=os.getenv("SONIOX_API_KEY"),
    url="wss://tts-rt.eu.soniox.com/tts-websocket",
    sample_rate=16000,
    text_aggregation_mode=TextAggregationMode.TOKEN,
    settings=SonioxTTSService.Settings(
        model="tts-rt-v1",
        voice="Adrian",
        language="en",
    ),
)
```

---

### 4. SONIOX - Pipecat Voice Agent Example

**Docs**: https://soniox.com/docs/integrations/pipecat/voice-agent
**GitHub**: https://github.com/pipecat-ai/pipecat/blob/main/examples/voice/voice-soniox.py

```python
import os
from pipecat.pipeline.pipeline import Pipeline
from pipecat.services.soniox.stt import SonioxSTTService
from pipecat.services.soniox.tts import SonioxTTSService

stt = SonioxSTTService(api_key=os.getenv("SONIOX_API_KEY"))
tts = SonioxTTSService(
    api_key=os.getenv("SONIOX_API_KEY"),
    settings=SonioxTTSService.Settings(voice="Adrian"),
)

pipeline = Pipeline([
    transport.input(),
    stt,
    llm,
    tts,
    transport.output(),
])
```

---

### 5. SONIOX API Keys

**Console**: https://console.soniox.com/org/beaf5259-315e-4635-a144-4aacd4ab9bac/projects/756e9d46-5651-40a0-8014-fa6511434bf7/api/keys/

> Lưu ý: Trang console yêu cầu đăng nhập. Truy cập trực tiếp tại link trên.

---

### 6. SONIOX - Pipecat Source Code Details

> Thông tin từ đọc source code tại `C:\pipecat-main\pipecat\src\pipecat\services\soniox\`

#### Soniox STT Internal Details

- **Keepalive protocol**: Gửi `{"type": "keepalive"}` thay vì silent audio
- **Finalize message**: Khi VAD detect user stopped speaking, gửi `{"type": "finalize"}` để Soniox trả final tokens ngay
- **Metrics**: `can_generate_metrics()` = True (hỗ trợ processing metrics)
- **Tracing**: Dùng `@traced_stt` decorator cho observability
- **Settings update**: Thay đổi settings → trigger disconnect + reconnect cycle

#### Soniox TTS Internal Details

- **Per-stream config**: Mỗi `stream_id` gửi config message riêng với `api_key`, `model`, `voice`, `audio_format`, `language`, `sample_rate`
- **Stream lifecycle**: `on_turn_context_created` → mở stream sẵn → text đến → gửi text → audio về → cancel khi interrupt
- **Idle timeout**: Soniox TTS timeout 20-30s, Pipecat gửi keepalive mỗi 20s

#### Real-time Translation trong Pipecat Context

Soniox STT hỗ trợ **translation terms** qua `SonioxContextObject.translation_terms`:
```python
SonioxContextTranslationTerm(source="St John's", target="St John's")
```
Tuy nhiên, Pipecat integration **không có built-in speech-to-speech translation** — focused vào speech-to-text transcription. Muốn dịch cần dùng Soniox server-side features hoặc LLM.

---

## PIPECAT CORE COMPONENTS

### VAD (Voice Activity Detection) Options

| VAD | File | Sample Rates | Đặc điểm |
|-----|------|-------------|----------|
| `SileroVADAnalyzer` | `audio/vad/silero.py` | 8000, 16000 Hz | Default, miễn phí, ONNX model bundled |
| `AICVADAnalyzer` | `audio/vad/aic_vad.py` | Any | Binary detection (1.0/0.0), configurable sensitivity |
| `KrispVivaVadAnalyzer` | `audio/vad/krisp_viva_vad.py` | 8000-48000 Hz | Probability (0.0-1.0), cần Krisp model file |

#### VADParams (shared)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `confidence` | `float` | `0.7` | Min confidence threshold |
| `start_secs` | `float` | `0.2` | Duration trước khi confirm voice start |
| `stop_secs` | `float` | `0.2` | Duration trước khi confirm voice stop |
| `min_volume` | `float` | `0.6` | Minimum audio volume threshold |

#### VAD Usage trong Pipeline

```python
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.processors.aggregators.llm_response_universal import LLMUserAggregatorParams

user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
    context,
    user_params=LLMUserAggregatorParams(
        vad_analyzer=SileroVADAnalyzer(),
    ),
)
```

---

### LLMContextAggregatorPair

```python
LLMContextAggregatorPair(
    context: LLMContext,
    user_params: LLMUserAggregatorParams | None = None,
    assistant_params: LLMAssistantAggregatorParams | None = None,
)
```

#### LLMUserAggregatorParams

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `vad_analyzer` | `VADAnalyzer | None` | `None` | VAD instance |
| `audio_idle_timeout` | `float` | `1.0` | Timeout force speech stop khi không có audio (0 = disable) |
| `user_turn_stop_timeout` | `float` | `5.0` | Giây trước khi coi user turn kết thúc |
| `user_idle_timeout` | `float` | `0` | Giây idle trước khi emit `on_user_turn_idle` (0 = disable) |
| `user_turn_strategies` | `UserTurnStrategies | None` | `None` | Turn start/stop strategies |
| `user_mute_strategies` | `list[BaseUserMuteStrategy]` | `[]` | User mute strategies |
| `filter_incomplete_user_turns` | `bool` | `False` | Deprecated → dùng `user_turn_strategies` |

#### LLMAssistantAggregatorParams

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enable_auto_context_summarization` | `bool` | `False` | Auto summarize khi vượt token/message limits |
| `auto_context_summarization_config` | `LLMAutoContextSummarizationConfig | None` | `None` | Config cho summarization |

#### User Aggregator Events

| Event | Description |
|-------|-------------|
| `on_user_turn_started` | User bắt đầu nói |
| `on_user_turn_stopped` | User dừng nói |
| `on_user_turn_stop_timeout` | Không detect được stop |
| `on_user_turn_idle` | User idle quá timeout |
| `on_mute_started` | User bị mute |
| `on_mute_stopped` | User unmute |

---

### SmallWebRTCTransport

#### Transport Event Handlers

| Event | Signature | Description |
|-------|-----------|-------------|
| `on_client_connected` | `(transport, client)` | Client connected |
| `on_client_disconnected` | `(transport, client)` | Client disconnected |
| `on_app_message` | `(transport, message, sender)` | Data channel message received |

#### SmallWebRTCConnection Events

| Event | Description |
|-------|-------------|
| `app-message` | Data channel message |
| `track-started` | Media track started |
| `track-ended` | Media track ended |
| `connecting` | Connection establishing |
| `connected` | Connection established |
| `disconnected` | Connection lost |
| `closed` | Connection closed |
| `failed` | Connection failed |

#### Connection Constructor

```python
SmallWebRTCConnection(
    ice_servers: list[str] | list[IceServer] | None = None,
    connection_timeout_secs: int = 60,
)
```

---

### Pipeline Architecture

Standard voice agent pipeline:
```
transport.input() → STT → user_aggregator → LLM → TTS → transport.output() → assistant_aggregator
```

- `user_aggregator`: Giữa STT và LLM, xử lý transcription aggregation và turn management
- `assistant_aggregator`: Sau `transport.output()`, track bot responses
- Cả 2 aggregators share cùng 1 `LLMContext` instance
- VAD cấu hình trong `LLMUserAggregatorParams(vad_analyzer=...)`, không phải pipeline stage riêng

---

### Pipecat Examples (Soniox)

| Example | File | Mô tả |
|---------|------|-------|
| Voice agent | `examples/voice/voice-soniox.py` | Full STT + LLM + TTS pipeline |
| STT settings update | `examples/update-settings/stt/stt-soniox.py` | Runtime language switch |
| Transcription only | `examples/transcription/transcription-soniox.py` | STT + VADProcessor, no LLM/TTS |

---

## PROVIDER KHÁC (TODO)

### Deepgram
- STT: https://deepgram.com
- TTS: Có sẵn
- Pipecat: `pipecat.services.deepgram.stt`, `pipecat.services.deepgram.tts`

### OpenAI
- STT: Whisper API
- LLM: GPT-4o, GPT-4o-mini
- TTS: OpenAI TTS
- Pipecat: `pipecat.services.openai.stt`, `pipecat.services.openai.llm`, `pipecat.services.openai.tts`

### Google
- STT: Google Speech-to-Text
- LLM: Gemini Live, Gemini Flash
- TTS: Google TTS
- Pipecat: `pipecat.services.google.stt`, `pipecat.services.google.gemini_live.llm`, `pipecat.services.google.tts`

### Anthropic
- LLM: Claude 3.5 Sonnet, Claude 3 Opus
- Pipecat: `pipecat.services.anthropic.llm`

### Groq
- STT: Groq Whisper
- LLM: Llama, Mixtral
- Pipecat: `pipecat.services.groq.stt`, `pipecat.services.groq.llm`

### Mistral
- STT: Mistral STT
- LLM: Mistral Large, Medium
- Pipecat: `pipecat.services.mistral.stt`, `pipecat.services.mistral.llm`

### ElevenLabs
- TTS: ElevenLabs TTS
- Pipecat: `pipecat.services.elevenlabs.tts`

### Cartesia
- TTS: Cartesia TTS
- Pipecat: `pipecat.services.cartesia.tts`

### AssemblyAI
- STT: AssemblyAI STT
- Pipecat: `pipecat.services.assemblyai.stt`

---

## Pipecat Install Commands

```bash
# STT providers
pip install "pipecat-ai[deepgram]"     # Deepgram STT
pip install "pipecat-ai[openai]"       # OpenAI STT/LLM/TTS
pip install "pipecat-ai[google]"       # Google STT/LLM/TTS
pip install "pipecat-ai[soniox]"       # Soniox STT/TTS
pip install "pipecat-ai[groq]"         # Groq STT/LLM
pip install "pipecat-ai[mistral]"      # Mistral STT/LLM
pip install "pipecat-ai[assemblyai]"   # AssemblyAI STT

# TTS providers
pip install "pipecat-ai[elevenlabs]"   # ElevenLabs TTS
pip install "pipecat-ai[cartesia]"     # Cartesia TTS

# WebRTC transport
pip install "pipecat-ai[webrtc]"

# Multiple providers
pip install "pipecat-ai[soniox,google,webrtc]"
```

---

## Tham khảo

- Pipecat docs: https://docs.pipecat.ai
- Pipecat API reference: https://reference-server.pipecat.ai
- Pipecat GitHub: https://github.com/pipecat-ai/pipecat
- Pipecat source (local): `C:\pipecat-main\pipecat\src\pipecat\`
- Soniox docs: https://soniox.com/docs
- Soniox Pipecat integration: https://soniox.com/docs/integrations/pipecat
- Soniox STT source: `C:\pipecat-main\pipecat\src\pipecat\services\soniox\stt.py`
- Soniox TTS source: `C:\pipecat-main\pipecat\src\pipecat\services\soniox\tts.py`
