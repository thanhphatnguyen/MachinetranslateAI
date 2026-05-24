import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gemini_socket_service.dart';
import 'audio_stream_service.dart';
import 'audio_player_service.dart';
import 'pipecat_service.dart';
import '../models/ai_translate_config.dart';

/// Service mode
enum ServiceMode { none, geminiLive, offlineTranslate, aiTranslate }

/// Unified Background Service cho cả Gemini Live và Offline Translate
class UnifiedBackgroundService {
  static final UnifiedBackgroundService _instance =
      UnifiedBackgroundService._();
  factory UnifiedBackgroundService() => _instance;
  UnifiedBackgroundService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  ServiceMode _currentMode = ServiceMode.none;

  ServiceMode get currentMode => _currentMode;
  bool get isRunning => _currentMode != ServiceMode.none;
  bool get isGeminiLiveRunning => _currentMode == ServiceMode.geminiLive;
  bool get isOfflineTranslateRunning =>
      _currentMode == ServiceMode.offlineTranslate;
  bool get isAiTranslateRunning => _currentMode == ServiceMode.aiTranslate;

  /// Khởi tạo service configuration (gọi 1 lần ở main.dart)
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    const AndroidNotificationChannel geminiChannel = AndroidNotificationChannel(
      'gemini_live_channel',
      'AI Translation Service',
      description: 'Đang nghe và dịch thuật realtime 24/7...',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    const AndroidNotificationChannel offlineChannel =
        AndroidNotificationChannel(
          'offline_translate_channel',
          'Offline Translate Service',
          description: 'Đang nghe và dịch thuật offline...',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        );

    const AndroidNotificationChannel aiTranslateChannel =
        AndroidNotificationChannel(
          'ai_translate_channel',
          'AI Translate Service',
          description: 'Đang nghe và dịch thuật qua Pipecat...',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(geminiChannel);

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(offlineChannel);

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(aiTranslateChannel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onUnifiedServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'gemini_live_channel',
        initialNotificationTitle: '🎧 AI Smart Gemini',
        initialNotificationContent: 'Đang khởi động hệ thống...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onUnifiedServiceStart,
      ),
    );

    debugPrint('✅ [UnifiedBG] Service initialized');
  }

  /// Bắt đầu Gemini Live
  Future<bool> startGeminiLive() async {
    if (_currentMode == ServiceMode.geminiLive) return true;
    if (_currentMode != ServiceMode.none) await stop();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('service_mode', 'geminiLive');

      final isRunning = await _service.isRunning();
      if (!isRunning) {
        await _service.startService();
      } else {
        _service.invoke('startGeminiLive');
      }

      _currentMode = ServiceMode.geminiLive;
      debugPrint('🟢 [UnifiedBG] Gemini Live started');
      return true;
    } catch (e) {
      debugPrint('❌ [UnifiedBG] Failed to start Gemini Live: $e');
      return false;
    }
  }

  /// Bắt đầu Offline Translate
  Future<bool> startOfflineTranslate() async {
    if (_currentMode == ServiceMode.offlineTranslate) return true;
    if (_currentMode != ServiceMode.none) await stop();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('service_mode', 'offlineTranslate');

      final isRunning = await _service.isRunning();
      if (!isRunning) {
        await _service.startService();
      } else {
        _service.invoke('startOfflineTranslate');
      }

      _currentMode = ServiceMode.offlineTranslate;
      debugPrint('🟢 [UnifiedBG] Offline Translate started');
      return true;
    } catch (e) {
      debugPrint('❌ [UnifiedBG] Failed to start Offline Translate: $e');
      return false;
    }
  }

  /// Dừng service
  Future<void> stop() async {
    if (_currentMode == ServiceMode.none) return;
    try {
      _service.invoke('stopService');
      _currentMode = ServiceMode.none;
      debugPrint('🔴 [UnifiedBG] Service stopped');
    } catch (e) {
      debugPrint('❌ [UnifiedBG] Failed to stop service: $e');
    }
  }

  Future<void> stopGeminiLive() async {
    if (_currentMode != ServiceMode.geminiLive) return;
    await stop();
  }

  Future<void> stopOfflineTranslate() async {
    if (_currentMode != ServiceMode.offlineTranslate) return;
    await stop();
  }

  /// Bắt đầu AI Translate
  Future<bool> startAiTranslate() async {
    if (_currentMode == ServiceMode.aiTranslate) return true;
    if (_currentMode != ServiceMode.none) await stop();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('service_mode', 'aiTranslate');

      final isRunning = await _service.isRunning();
      if (!isRunning) {
        await _service.startService();
      } else {
        _service.invoke('startAiTranslate');
      }

      _currentMode = ServiceMode.aiTranslate;
      debugPrint('🟢 [UnifiedBG] AI Translate started');
      return true;
    } catch (e) {
      debugPrint('❌ [UnifiedBG] Failed to start AI Translate: $e');
      return false;
    }
  }

  /// Dừng AI Translate
  Future<void> stopAiTranslate() async {
    if (_currentMode != ServiceMode.aiTranslate) return;
    await stop();
  }
}

/// Unified entry point cho background service
@pragma('vm:entry-point')
void onUnifiedServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  print("=======================================");
  print("🚀🚀🚀 [UNIFIED BG] ISOLATE ĐÃ THỨC TỈNH!");
  print("=======================================");

  final prefs = await SharedPreferences.getInstance();
  String mode = prefs.getString('service_mode') ?? 'none';

  print("📋 [UnifiedBG] Mode: $mode");

  service.on('startGeminiLive').listen((event) {
    print("🔄 [UnifiedBG] Chuyển sang Gemini Live mode");
    mode = 'geminiLive';
    _startGeminiLiveMode(service);
  });

  service.on('startOfflineTranslate').listen((event) {
    print("🔄 [UnifiedBG] Chuyển sang Offline Translate mode");
    mode = 'offlineTranslate';
    _startOfflineTranslateMode(service);
  });

  service.on('startAiTranslate').listen((event) {
    print("🔄 [UnifiedBG] Chuyển sang AI Translate mode");
    mode = 'aiTranslate';
    _startAiTranslateMode(service);
  });

  service.on('stopService').listen((event) {
    print("⏹️ [UnifiedBG] Đã nhận lệnh TẮT!");
    _stopAllServices();
    service.stopSelf();
  });

  if (mode == 'geminiLive') {
    _startGeminiLiveMode(service);
  } else if (mode == 'offlineTranslate') {
    _startOfflineTranslateMode(service);
  } else if (mode == 'aiTranslate') {
    _startAiTranslateMode(service);
  }
}

/// Bắt đầu Gemini Live mode
void _startGeminiLiveMode(ServiceInstance service) async {
  try {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "🎧 AI Smart Gemini",
        content: "Đang kết nối...",
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('settings_api_key') ?? "";
    final model =
        prefs.getString('settings_model') ?? "gemini-3.1-flash-live-preview";
    final prompt =
        prefs.getString('settings_prompt') ??
        "Bạn là một thông dịch viên, khi nghe tiếng Đức hãy phiên dịch sang tiếng Việt, không nói gì thêm, không giải thích gì thêm!";

    if (apiKey.isEmpty) {
      print("❌ [GeminiLive] Không tìm thấy API Key!");
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "❌ AI Smart Gemini",
          content: "Lỗi: Chưa nhập API Key!",
        );
      }
      return;
    }

    geminiSocketService.onAudioResponseComplete = (base64Audio) {
      print("🤖 [GeminiLive] Đã nhận âm thanh từ AI");
      audioPlayerService.playAudio(base64Audio);
    };

    geminiSocketService.onSocketError = (errorMsg) {
      print("❌ [GeminiLive] Lỗi: $errorMsg");
    };

    print("🌐 [GeminiLive] Đang kết nối...");
    await geminiSocketService.connect(apiKey, model, prompt);

    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (geminiSocketService.isInitialized) {
        timer.cancel();
        print("🎙️ [GeminiLive] AI sẵn sàng! Đang nghe...");

        audioStreamService.startStreaming((base64Chunk) {
          geminiSocketService.sendAudioChunk(base64Chunk);
        });

        int tick = 0;
        Timer.periodic(const Duration(seconds: 1), (lifeTimer) {
          tick++;
          String dots = List.filled((tick % 3) + 1, ".").join("");
          if (service is AndroidServiceInstance) {
            service.setForegroundNotificationInfo(
              title: "🎧 AI Smart Gemini",
              content: "🟢 Đang nghe và dịch thuật$dots",
            );
          }
        });
      }
    });
  } catch (e) {
    print("❌❌❌ [GeminiLive] LỖI: $e");
  }
}

/// Bắt đầu Offline Translate mode
void _startOfflineTranslateMode(ServiceInstance service) {
  try {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "🎤 Offline Translate",
        content: "Đang nghe và dịch thuật...",
      );
    }

    int tick = 0;
    Timer.periodic(const Duration(seconds: 1), (timer) {
      tick++;
      String dots = List.filled((tick % 3) + 1, ".").join("");
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "🎤 Offline Translate",
          content: "🟢 Đang nghe$dots",
        );
      }
    });

    print("✅ [OfflineTranslate] Đã bắt đầu");
  } catch (e) {
    print("❌❌❌ [OfflineTranslate] LỖI: $e");
  }
}

/// Bắt đầu AI Translate mode
void _startAiTranslateMode(ServiceInstance service) async {
  try {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "🌐 AI Translate",
        content: "Đang kết nối...",
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('ai_translate_server_url') ?? '';

    if (serverUrl.isEmpty) {
      print("❌ [AiTranslate] Không tìm thấy Server URL!");
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "❌ AI Translate",
          content: "Lỗi: Chưa nhập Server URL!",
        );
      }
      return;
    }

    final pipecatService = PipecatService();
    final config = AiTranslateConfig();
    await config.load();

    // ── Gửi transcript + audioTarget về UI ──────────────────────────────
    pipecatService.transcripts.listen((transcript) {
      service.invoke('aiTranscript', {
        'text': transcript.text,
        'speaker': transcript.speaker,
        'isFinal': transcript.isFinal,
        'sourceText': transcript.sourceText,
        'isProTranslate': transcript.isProTranslate,
        'audioTarget': transcript.audioTarget, // ← MỚI: forward về UI
        'translationLanguage': transcript.translationLanguage,
        'sourceLanguage': transcript.sourceLanguage,
      });
    });

    pipecatService.partialTranscripts.listen((partial) {
      service.invoke('aiPartialTranscript', {
        'text': partial.text,
        'speaker': partial.speaker,
        'language': partial.language,
      });
    });

    pipecatService.connectionState.listen((state) {
      service.invoke('aiConnectionState', {'state': state.toString()});
    });

    pipecatService.errors.listen((error) {
      service.invoke('aiError', {'message': error});
    });

    print("🌐 [AiTranslate] Đang kết nối đến $serverUrl...");
    await pipecatService.connect(config);

    int tick = 0;
    Timer.periodic(const Duration(seconds: 1), (lifeTimer) {
      tick++;
      String dots = List.filled((tick % 3) + 1, ".").join("");
      if (service is AndroidServiceInstance) {
        final state = pipecatService.currentState;
        if (state == PipecatConnectionState.connected) {
          service.setForegroundNotificationInfo(
            title: "🌐 AI Translate",
            content: "🟢 Đang nghe và dịch thuật$dots",
          );
        } else if (state == PipecatConnectionState.connecting) {
          service.setForegroundNotificationInfo(
            title: "🌐 AI Translate",
            content: "Đang kết nối$dots",
          );
        } else if (state == PipecatConnectionState.error) {
          service.setForegroundNotificationInfo(
            title: "🌐 AI Translate",
            content: "❌ Lỗi kết nối",
          );
        }
      }
    });

    print("✅ [AiTranslate] Đã bắt đầu");
  } catch (e) {
    print("❌❌❌ [AiTranslate] LỖI: $e");
  }
}

/// Dừng tất cả services
void _stopAllServices() {
  print("🛑 [UnifiedBG] Đang dừng tất cả services...");
  audioStreamService.stopStreaming();
  geminiSocketService.disconnect();
  PipecatService().disconnect();
}
