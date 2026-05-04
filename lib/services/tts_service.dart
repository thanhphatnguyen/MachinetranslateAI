import 'package:flutter_tts/flutter_tts.dart';

/// Service wrapper cho Text-to-Speech
/// Sử dụng system TTS (Google TTS trên Android, Apple TTS trên iOS)
class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  String _language = "vi-VN";
  double _speechRate = 0.5;
  final double _volume = 1.0;
  final double _pitch = 1.0;

  /// Khởi tạo TTS engine
  Future<void> initialize() async {
    if (_isInitialized) return;

    await _flutterTts.setLanguage(_language);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setVolume(_volume);
    await _flutterTts.setPitch(_pitch);

    // Kiểm tra xem ngôn ngữ có được hỗ trợ không
    final languages = await _flutterTts.getLanguages;
    print("🔊 [TTS] Ngôn ngữ khả dụng: $languages");

    _isInitialized = true;
    print("✅ [TTS] Đã khởi tạo thành công ($languages)");
  }

  /// Đọc text thành giọng nói
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await initialize();
    print("🔊 [TTS] Đang đọc: $text");
    await _flutterTts.speak(text);
  }

  /// Dừng đọc
  Future<void> stop() async {
    await _flutterTts.stop();
  }

  /// Đặt ngôn ngữ TTS
  Future<void> setLanguage(String language) async {
    _language = language;
    await _flutterTts.setLanguage(language);
  }

  /// Đặt tốc độ đọc (0.0 - 1.0)
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    await _flutterTts.setSpeechRate(rate);
  }

  /// Lấy danh sách ngôn ngữ hỗ trợ
  Future<List<dynamic>> getLanguages() async {
    return await _flutterTts.getLanguages;
  }

  /// Giải phóng tài nguyên
  void dispose() {
    _flutterTts.stop();
  }
}
