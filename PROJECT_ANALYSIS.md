# Phan tich du an MachinetranslateAI

## Tong quan

MachinetranslateAI la ung dung Flutter da nen tang, huong den dich may va dich giong noi bang AI. Du an hien co 2 nhanh tinh nang chinh:

- **AI Live Translate**: nghe micro trong foreground/background, gui audio len Google Gemini Live qua WebSocket, nhan audio phan hoi va phat ra loa.
- **Offline Translate**: giao dien dich offline theo huong STT -> MT -> TTS, hien moi hoan thanh UI va TTS he thong; STT/MT van la TODO.

Ung dung dang duoc thiet ke theo theme nen toi, mau nhan xanh la, co animation o man hinh home va cac card tinh nang.

## Cong nghe va phu thuoc

- **Framework**: Flutter, Dart SDK `^3.11.5`.
- **State/UI**: StatefulWidget co animation controller truc tiep, chua dung state management rieng.
- **Realtime AI**: `web_socket_channel` ket noi Gemini Live API.
- **Luu cau hinh**: `shared_preferences` luu API key, model, prompt.
- **Background**: `flutter_background_service` va `flutter_local_notifications` de chay foreground service tren Android.
- **Audio input**: `record` thu PCM 16-bit, 16 kHz, mono.
- **Audio output**: `audioplayers` phat byte WAV tu RAM.
- **Permission**: `permission_handler` xin quyen microphone va notification.
- **Offline/TTS**: `flutter_tts`; da khai bao them `sherpa_onnx`, `llamadart`, `path_provider`, `http` nhung chua tich hop logic chinh.
- **Icon**: `flutter_launcher_icons`, asset chinh `assets/icon.png`.

## Cau truc thu muc

```text
lib/
  main.dart
  screens/
    home_screen.dart
    gemini_live_screen.dart
    offline_translate_screen.dart
  services/
    background_task_service.dart
    gemini_socket_service.dart
    audio_stream_service.dart
    audio_player_service.dart
    tts_service.dart
  utils/
    audio_buffer_util.dart
android/ ios/ macos/ linux/ windows/ web/
  Thu muc platform mac dinh cua Flutter
test/
  widget_test.dart
```

## Luong khoi dong ung dung

1. `lib/main.dart` goi `WidgetsFlutterBinding.ensureInitialized()`.
2. Goi `initializeService()` trong `services/background_task_service.dart` de cau hinh background service va notification channel.
3. Render `MyApp`, dat theme dark va mo `HomeScreen`.
4. `HomeScreen` cho chon cac che do:
   - Offline Translate: mo `OfflineTranslateScreen`.
   - AI Live Translate: mo `GeminiLiveScreen`.
   - AI Translate: hien SnackBar tinh nang dang phat trien.

## Module man hinh

### `lib/screens/home_screen.dart`

- Man hinh chinh co gradient nen toi, logo pulse, fade-in va stagger animation cho card.
- Dieu huong bang `PageRouteBuilder` voi fade + slide transition.
- 3 card tinh nang:
  - Offline Translate: da co man hinh UI rieng.
  - AI Live Translate: tinh nang live Gemini.
  - AI Translate: placeholder/TODO.

### `lib/screens/gemini_live_screen.dart`

- Quan ly 3 cau hinh nguoi dung:
  - `settings_api_key`
  - `settings_model`, mac dinh `gemini-3.1-flash-live-preview`
  - `settings_prompt`, prompt mac dinh yeu cau dich tieng Duc sang tieng Viet.
- Doc/ghi cau hinh bang `SharedPreferences`.
- Nut bat dau:
  - Kiem tra API key.
  - Xin quyen notification va microphone.
  - Neu co microphone permission thi start `FlutterBackgroundService`.
- Nut dung:
  - Goi `service.invoke("stopService")`.
- Co modal cai dat bang `showModalBottomSheet`.

### `lib/screens/offline_translate_screen.dart`

- UI chia thanh vung ngon ngu nguon, nut dich, vung ban dich va nut push-to-talk.
- Hien status STT/MT/TTS tren app bar.
- Hien tai chi TTS duoc khoi tao bang `TtsService`.
- Dich text hien la gia lap bang `Future.delayed`, chua tich hop model offline.
- Push-to-talk moi doi trang thai UI; STT chua duoc ket noi.

## Module service

### `lib/services/background_task_service.dart`

- Cau hinh `FlutterBackgroundService`:
  - Android foreground mode.
  - Notification channel `gemini_live_channel`.
  - Foreground notification id `888`.
- `onStart` chay trong isolate rieng:
  - Goi `DartPluginRegistrant.ensureInitialized()` va `WidgetsFlutterBinding.ensureInitialized()`.
  - Doc API key/model/prompt tu `SharedPreferences`.
  - Neu thieu API key thi cap nhat notification loi va dung service.
  - Gan callback audio tu Gemini sang `audioPlayerService.playAudio`.
  - Ket noi Gemini socket.
  - Doi `geminiSocketService.isInitialized`, sau do bat mic va gui chunk audio len Gemini.
  - Cap nhat notification moi giay de bao dang nghe/dich.
  - Lang nghe event `stopService` de stop mic, disconnect socket va stop service.

### `lib/services/gemini_socket_service.dart`

- Tao WebSocket den endpoint Gemini Live:
  - `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=...`
- Gui setup message gom model, system instruction va `responseModalities: ["AUDIO"]`.
- Parse message tra ve:
  - Nhan `setupComplete` de danh dau da khoi tao.
  - Gom cac audio chunk base64 trong `serverContent.modelTurn.parts[].inlineData.data`.
  - Khi `turnComplete` hoac `generationComplete`, decode tung chunk, noi byte, encode lai base64 va goi callback phat audio.
- Gui input realtime voi mime type `audio/pcm;rate=16000`.

### `lib/services/audio_stream_service.dart`

- Dung `AudioRecorder.startStream` voi cau hinh PCM 16-bit, 16 kHz, mono.
- Moi chunk `Uint8List` duoc base64 encode va day qua callback.
- Co `stopStreaming()` de dung recorder.
- Ghi chu: service bo qua check quyen ben trong, phu thuoc UI da xin quyen truoc.

### `lib/services/audio_player_service.dart`

- Dung `audioplayers`.
- Cau hinh audio context de giam tranh gianh audio focus voi mic.
- Nhan audio PCM base64 tu Gemini, them WAV header 44 byte voi sample rate 24000 Hz, mono, 16-bit, sau do phat bang `BytesSource`.

### `lib/services/tts_service.dart`

- Wrapper quanh `FlutterTts`.
- Mac dinh ngon ngu `vi-VN`, speech rate `0.5`, volume `1.0`, pitch `1.0`.
- Ho tro initialize, speak, stop, setLanguage, setSpeechRate, getLanguages, dispose.

### `lib/utils/audio_buffer_util.dart`

- File dang trong, chua co logic.

## Cau hinh platform dang chu y

### Android

`android/app/src/main/AndroidManifest.xml` khai bao:

- `INTERNET`
- `RECORD_AUDIO`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_MICROPHONE`
- `WAKE_LOCK`
- `POST_NOTIFICATIONS`

Co service `id.flutter.flutter_background_service.BackgroundService` voi `android:foregroundServiceType="microphone"`.

Can kiem tra lai manifest vi hien co chuoi ``` nam ngay sau tag service, co kha nang lam XML khong hop le.

### iOS/macOS/windows/linux/web

- Cac thu muc platform chu yeu la scaffold mac dinh cua Flutter.
- Chua thay cau hinh rieng cho quyen microphone tren iOS/macOS trong phan da doc, can bo sung neu build cho Apple platform.

## Lenh van hanh thuong dung

```bash
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk
```

Neu thay doi icon:

```bash
dart run flutter_launcher_icons
```

## Trang thai test va chat luong

- `test/widget_test.dart` van la test counter mac dinh cua Flutter, khong phu hop voi app hien tai vi app khong co counter hay nut `+`.
- Chua co unit test cho cac service audio, websocket, background service.
- Chua co widget test cho `HomeScreen`, `GeminiLiveScreen`, `OfflineTranslateScreen`.
- Nhieu log/comment trong source dang bi loi encoding tieng Viet, lam kho doc va co the gay hien thi sai.

## Rui ro / van de can sua som

1. **Loi cu phap nghiem trong trong `lib/services/gemini_socket_service.dart`**: file co dong literal `... (1 duplicate lines)` nen Dart se khong compile.
2. **AndroidManifest co ky tu thua**: sau service tag co ``` nen co kha nang XML build fail.
3. **Test mac dinh se fail**: widget test dang tim counter `0/1` va icon `+`, khong dung voi UI hien tai.
4. **API key luu plain text**: `SharedPreferences` khong phai noi luu secret an toan; nen can nhac secure storage.
5. **Khong co retry/reconnect WebSocket**: khi Gemini dong ket noi, service reset state nhung chua tu reconnect.
6. **Timer background chua duoc quan ly day du**: life timer tao trong background khong duoc cancel ro rang khi stop, co the tao hanh vi kho debug.
7. **Quyen va cau hinh iOS/macOS chua ro**: neu can ho tro Apple platform, can them usage description cho microphone/speech/background mode.
8. **Offline Translate moi la prototype**: STT va MT chua tich hop du `sherpa_onnx`/`llamadart`.
9. **Global singleton service**: de dung nhanh nhung kho test, kho reset state va co rui ro khi isolate/background phuc tap.
10. **Log qua nhieu trong audio stream**: log moi chunk audio co the anh huong hieu nang va lam nhiu console.

## De xuat roadmap

### Uu tien 1: Lam app build duoc

- Xoa dong `... (1 duplicate lines)` trong `gemini_socket_service.dart`.
- Xoa ky tu ``` trong `AndroidManifest.xml`.
- Cap nhat/xoa widget test mac dinh.
- Chay `flutter analyze` va `flutter test`.

### Uu tien 2: On dinh AI Live Translate

- Them validate model/API key va hien loi tu socket len UI.
- Them reconnect/backoff khi WebSocket bi dong.
- Quan ly timer/subscription de cleanup chac chan khi stop service.
- Giam log audio chunk hoac them debug flag.
- Can nhac luu API key bang secure storage.

### Uu tien 3: Hoan thien Offline Translate

- Tich hop STT bang `sherpa_onnx`.
- Tich hop MT bang `llamadart` voi model dich offline.
- Dinh nghia co che download/kiem tra model bang `path_provider` va `http`.
- Cap nhat status STT/MT/TTS theo trang thai that.

### Uu tien 4: Kiem thu va bao tri

- Viet widget test cho HomeScreen va flow mo settings.
- Tach logic parse Gemini message de unit test rieng.
- Tach audio WAV header thanh util co test.
- Chuan hoa encoding UTF-8 cho tat ca file source.

## Tom tat nhanh

Du an la Flutter app dich AI, trong do phan AI Live Translate da co kien truc kha day du: UI cai dat -> background service -> mic stream -> Gemini Live WebSocket -> audio playback. Phan Offline Translate moi o muc UI/TTS va con nhieu TODO. Viec can lam ngay la sua cac loi compile/config hien huu, sau do bo sung cleanup/retry cho background realtime va thay test mau bang test dung voi ung dung.
