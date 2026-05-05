import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service chạy ngầm cho Offline Translate
/// Giữ app sống khi STT đang hoạt động
class OfflineBackgroundService {
  static final OfflineBackgroundService _instance = OfflineBackgroundService._();
  factory OfflineBackgroundService() => _instance;
  OfflineBackgroundService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// Khởi tạo service configuration
  static Future<void> initialize() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'offline_translate_channel',
      'Offline Translate Service',
      description: 'Đang nghe và dịch thuật offline...',
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
        ?.createNotificationChannel(channel);

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onOfflineServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'offline_translate_channel',
        initialNotificationTitle: '🎤 Offline Translate',
        initialNotificationContent: 'Đang khởi động...',
        foregroundServiceNotificationId: 999,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onOfflineServiceStart,
      ),
    );
  }

  /// Bắt đầu chạy ngầm
  Future<void> start() async {
    if (_isRunning) return;

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
    }
    _isRunning = true;
    debugPrint('🟢 [OfflineBG] Service started');
  }

  /// Dừng chạy ngầm
  Future<void> stop() async {
    if (!_isRunning) return;

    _service.invoke('stopOfflineService');
    _isRunning = false;
    debugPrint('🔴 [OfflineBG] Service stopped');
  }

  /// Cập nhật trạng thái notification
  void updateStatus(String status) {
    _service.invoke('updateStatus', {'status': status});
  }
}

/// Entry point cho background service
@pragma('vm:entry-point')
void onOfflineServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  print("=======================================");
  print("🎤🎤🎤 [OFFLINE BG] ISOLATE ĐÃ THỨC TỈNH!");
  print("=======================================");

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "🎤 Offline Translate",
      content: "Đang nghe và dịch thuật...",
    );
  }

  // Lắng nghe sự kiện cập nhật trạng thái
  service.on('updateStatus').listen((event) {
    if (event != null && service is AndroidServiceInstance) {
      final status = event['status'] ?? 'Đang xử lý...';
      service.setForegroundNotificationInfo(
        title: "🎤 Offline Translate",
        content: status,
      );
    }
  });

  // Tạo nhịp tim để giữ service sống
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

  // Lắng nghe sự kiện tắt
  service.on('stopOfflineService').listen((event) {
    print("⏹️ [Offline BG] Đã nhận lệnh TẮT!");
    service.stopSelf();
  });
}
