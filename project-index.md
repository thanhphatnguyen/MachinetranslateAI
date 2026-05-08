# MachinetranslateAI Project Index

## Overview
Flutter/Dart mobile application for machine translation with AI capabilities.

## Project Structure
- **22 Dart files** across lib/ directory
- **5,604 total lines** of code
- **32 classes**, **7 widgets**, **90 functions**

## Architecture

### Screens (UI Layer)
| File | Widget | Purpose |
|------|--------|---------|
| `lib/screens/home_screen.dart` (16.7KB) | HomeScreen | Main navigation hub |
| `lib/screens/ai_translate_screen.dart` (30.9KB) | AiTranslateScreen | AI-powered translation with chat UI |
| `lib/screens/offline_translate_screen.dart` (31.7KB) | OfflineTranslateScreen | Offline translation with local models |
| `lib/screens/gemini_live_screen.dart` (14.7KB) | GeminiLiveScreen | Real-time Gemini API integration |

### Services (Business Logic)
| File | Class | Lines |
|------|-------|-------|
| `lib/services/unified_background_service.dart` | UnifiedBackgroundService | 10.4KB |
| `lib/services/pipecat_service.dart` | PipecatService, PipecatTranscript | 7.6KB |
| `lib/services/hy_mt_translate_service.dart` | HyMtTranslateService, HyMtModelLoadException | 5.9KB |
| `lib/services/gemini_socket_service.dart` | GeminiSocketService | 5.3KB |
| `lib/services/stt_service.dart` | SttService | 4.6KB |
| `lib/services/mt_service.dart` | MtService | 4.4KB |
| `lib/services/tts_service.dart` | TtsService | 4.3KB |
| `lib/services/offline_background_service.dart` | OfflineBackgroundService | 4.0KB |
| `lib/services/audio_player_service.dart` | AudioPlayerService | - |
| `lib/services/audio_stream_service.dart` | AudioStreamService | - |
| `lib/services/service_manager.dart` | ServiceManager | - |
| `lib/services/translation_queue.dart` | TranslationQueue, TranslationResult | - |

### Models
| File | Class |
|------|-------|
| `lib/models/ai_translate_config.dart` | AiTranslateConfig |

### Widgets
| File | Widget |
|------|--------|
| `lib/widgets/model_download_dialog.dart` | ModelDownloadDialog |

## Key Data Flows

### AI Translation Flow
1. User input → AiTranslateScreen
2. ServiceManager → GeminiSocketService/PipecatService
3. Translation result → Chat UI

### Offline Translation Flow
1. User input → OfflineTranslateScreen
2. HyMtTranslateService (local model)
3. TranslationQueue → Background processing

### Background Services
- UnifiedBackgroundService: Orchestrates all background tasks
- OfflineBackgroundService: Manages offline model operations
- Audio services: STT/TTS integration

## Dependencies (from pubspec.yaml)
- Flutter SDK
- Gemini API (Google AI)
- Pipecat (voice processing)
- HyMT (offline translation models)
- Audio/TTS/STT libraries

## Configuration
- AI settings: `lib/models/ai_translate_config.dart`
- Model download: `lib/widgets/model_download_dialog.dart`
