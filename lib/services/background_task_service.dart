import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Import 2 file dịch vụ cốt lõi
import 'gemini_socket_service.dart';
import 'audio_stream_service.dart';
import 'audio_player_service.dart';

// ==========================================
// HÀM KHỞI TẠO (Gọi 1 lần ở main.dart)
// ==========================================
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'gemini_live_channel', // id
    'AI Translation Service', // name
    description: 'Đang nghe và dịch thuật realtime 24/7...', // description
    importance: Importance.low, // <-- Ép xuống mức Thấp để không hiện pop-up
    playSound: false, // <-- Khóa mõm tiếng Ting Ting
    enableVibration: false, // <-- Cấm rung
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'gemini_live_channel',
      initialNotificationTitle: '🎧 AI Smart Gemini',
      initialNotificationContent: 'Đang khởi động hệ thống...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart),
  );
}

// ==========================================
// KHÔNG GIAN CỦA ISOLATE (CHẠY NGẦM)
// ==========================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // BẮT BUỘC PHẢI CÓ 2 DÒNG NÀY ĐỂ KÉO SHAREDPREFERENCES LÊN
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  print("=======================================");
  print("🚀🚀🚀 [BACKGROUND] ISOLATE ĐÃ THỨC TỈNH!");
  print("=======================================");

  try {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "🎧 AI Smart Gemini",
        content: "Hệ thống đang nạp dữ liệu...",
      );
    }

    // 2. ĐỌC CÀI ĐẶT
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('settings_api_key') ?? "";
    final model =
        prefs.getString('settings_model') ?? "gemini-3.1-flash-live-preview";
    final prompt =
        prefs.getString('settings_prompt') ??
        "Bạn là một thông dịch viên, khi nghe tiếng Đức hãy phiên dịch sang tiếng Việt, không nói gì thêm, không giải thích gì thêm!";

    if (apiKey.isEmpty) {
      print("❌ [Background] Không tìm thấy API Key! Tự động tắt.");
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "❌ AI Smart Gemini",
          content: "Lỗi: Chưa nhập API Key!",
        );
      }
      service.stopSelf();
      return;
    }

    // 3. LẮNG NGHE AI TRẢ LỜI
    geminiSocketService.onAudioResponseComplete = (base64Audio) {
      print(
        "🤖 [AI TRẢ LỜI] Đã nhận luồng âm thanh! Độ dài Base64: ${base64Audio.length}",
      );

      // BẮN VÀO LOA ĐỂ PHÁT RA TIẾNG!
      audioPlayerService.playAudio(base64Audio);
    };

    geminiSocketService.onSocketError = (errorMsg) {
      print("❌ [Lỗi Gemini]: $errorMsg");
    };

    // 4. BẬT WEBSOCKET KẾT NỐI GEMINI
    print("🌐 [Background] Đang kết nối Google AI bằng API Key...");
    await geminiSocketService.connect(apiKey, model, prompt);

    // 5. CHỜ SETUP XONG THÌ BẬT MIC
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (geminiSocketService.isInitialized) {
        timer.cancel(); // Tắt vòng lặp kiểm tra

        print("🎙️ [Background] AI ĐÃ SẴN SÀNG! ĐANG NGHE...");

        // Bắt đầu thu âm gửi lên mạng
        audioStreamService.startStreaming((base64Chunk) {
          geminiSocketService.sendAudioChunk(base64Chunk);
        });

        // TẠO NHỊP TIM: Cập nhật thông báo mỗi giây để báo hiệu App đang sống
        int tick = 0;
        Timer.periodic(const Duration(seconds: 1), (lifeTimer) {
          tick++;
          // Hiệu ứng chấm bi: . -> .. -> ... -> .
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

    // 6. SỰ KIỆN TẮT
    service.on('stopService').listen((event) {
      print("⏹️ [Background] Đã nhận lệnh TẮT! Dọn dẹp chiến trường...");
      audioStreamService.stopStreaming();
      geminiSocketService.disconnect();
      service.stopSelf();
    });
  } catch (e) {
    print("❌❌❌ [LỖI NGHIÊM TRỌNG TRONG BACKGROUND]: $e");
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "❌ CRASH NGẦM",
        content: e.toString(),
      );
    }
  }
}
