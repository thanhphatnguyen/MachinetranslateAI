import 'package:flutter/material.dart';
import 'unified_background_service.dart';

/// Quản lý trạng thái chạy ngầm của cả 2 service
/// Sử dụng UnifiedBackgroundService
class ServiceManager {
  static final ServiceManager _instance = ServiceManager._();
  factory ServiceManager() => _instance;
  ServiceManager._();

  final UnifiedBackgroundService _bgService = UnifiedBackgroundService();

  /// Callback khi trạng thái thay đổi
  void Function(bool isRunning)? onStateChanged;

  bool get isGeminiLiveRunning => _bgService.isGeminiLiveRunning;
  bool get isOfflineTranslateRunning => _bgService.isOfflineTranslateRunning;
  bool get isAiTranslateRunning => _bgService.isAiTranslateRunning;
  bool get isAnyServiceRunning => _bgService.isRunning;

  /// Khởi tạo
  Future<void> initialize() async {
    debugPrint('🔄 [ServiceManager] Initialized');
  }

  /// Bắt đầu Gemini Live
  Future<bool> startGeminiLive() async {
    final success = await _bgService.startGeminiLive();
    if (success) {
      onStateChanged?.call(true);
    }
    return success;
  }

  /// Bắt đầu Offline Translate
  Future<bool> startOfflineTranslate() async {
    final success = await _bgService.startOfflineTranslate();
    if (success) {
      onStateChanged?.call(true);
    }
    return success;
  }

  /// Dừng service hiện tại
  Future<void> stopCurrentService() async {
    await _bgService.stop();
    onStateChanged?.call(false);
  }

  /// Dừng Gemini Live
  Future<void> stopGeminiLive() async {
    await _bgService.stopGeminiLive();
    onStateChanged?.call(false);
  }

  /// Dừng Offline Translate
  Future<void> stopOfflineTranslate() async {
    await _bgService.stopOfflineTranslate();
    onStateChanged?.call(false);
  }

  /// Bắt đầu AI Translate
  Future<bool> startAiTranslate() async {
    final success = await _bgService.startAiTranslate();
    if (success) {
      onStateChanged?.call(true);
    }
    return success;
  }

  /// Dừng AI Translate
  Future<void> stopAiTranslate() async {
    await _bgService.stopAiTranslate();
    onStateChanged?.call(false);
  }
}
