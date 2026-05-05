import 'package:flutter_tts/flutter_tts.dart';

/// Service wrapper cho Text-to-Speech
/// Sử dụng system TTS (Google TTS trên Android, Apple TTS trên iOS)
class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  String _language = "vi-VN";
  double _speechRate = 0.5;
  double _volume = 1.0;
  double _pitch = 1.0;
  bool _isSpeaking = false;

  /// Callback khi bắt đầu đọc
  void Function()? onStart;

  /// Callback khi hoàn thành đọc
  void Function()? onComplete;

  /// Callback khi có lỗi
  void Function(String error)? onError;

  /// Trạng thái đang đọc
  bool get isSpeaking => _isSpeaking;

  /// Khởi tạo TTS engine
  Future<void> initialize() async {
    if (_isInitialized) return;

    await _flutterTts.setLanguage(_language);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setVolume(_volume);
    await _flutterTts.setPitch(_pitch);

    // Set up callbacks
    _flutterTts.setStartHandler(() {
      _isSpeaking = true;
      onStart?.call();
    });

    _flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
      onComplete?.call();
    });

    _flutterTts.setErrorHandler((msg) {
      _isSpeaking = false;
      onError?.call(msg);
    });

    _flutterTts.setCancelHandler(() {
      _isSpeaking = false;
    });

    // Kiểm tra xem ngôn ngữ có được hỗ trợ không
    final languages = await _flutterTts.getLanguages;
    print("🔊 [TTS] Ngôn ngữ khả dụng: $languages");

    _isInitialized = true;
    print("✅ [TTS] Đã khởi tạo thành công");
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
    _isSpeaking = false;
  }

  /// Tạm dừng đọc
  Future<void> pause() async {
    await _flutterTts.pause();
  }

  /// Đặt ngôn ngữ TTS
  Future<void> setLanguage(String language) async {
    _language = language;
    if (_isInitialized) {
      await _flutterTts.setLanguage(language);
    }
  }

  /// Đặt tốc độ đọc (0.0 - 1.0)
  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    if (_isInitialized) {
      await _flutterTts.setSpeechRate(rate);
    }
  }

  /// Đặt âm lượng (0.0 - 1.0)
  Future<void> setVolume(double volume) async {
    _volume = volume;
    if (_isInitialized) {
      await _flutterTts.setVolume(volume);
    }
  }

  /// Đặt cao độ giọng (0.5 - 2.0)
  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    if (_isInitialized) {
      await _flutterTts.setPitch(pitch);
    }
  }

  /// Lấy danh sách ngôn ngữ hỗ trợ
  Future<List<dynamic>> getLanguages() async {
    await initialize();
    return await _flutterTts.getLanguages;
  }

  /// Lấy danh sách giọng nói
  Future<List<dynamic>> getVoices() async {
    await initialize();
    return await _flutterTts.getVoices;
  }

  /// Đặt giọng nói
  Future<void> setVoice(Map<String, String> voice) async {
    await _flutterTts.setVoice(voice);
  }

  /// Chuyển đổi mã ngôn ngữ sang mã TTS
  String getTtsLanguageCode(String langCode) {
    switch (langCode) {
      case 'vi':
        return 'vi-VN';
      case 'en':
        return 'en-US';
      case 'de':
        return 'de-DE';
      case 'fr':
        return 'fr-FR';
      case 'ja':
        return 'ja-JP';
      case 'ko':
        return 'ko-KR';
      case 'zh':
        return 'zh-CN';
      default:
        return 'vi-VN';
    }
  }

  /// Đọc text với ngôn ngữ cụ thể
  Future<void> speakWithLanguage(String text, String langCode) async {
    if (text.trim().isEmpty) return;
    await initialize();

    final ttsLang = getTtsLanguageCode(langCode);
    await _flutterTts.setLanguage(ttsLang);
    print("🔊 [TTS] Đang đọc ($ttsLang): $text");
    await _flutterTts.speak(text);

    // Khôi phục ngôn ngữ mặc định sau khi đọc xong
    _flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
      _flutterTts.setLanguage(_language);
      onComplete?.call();
    });
  }

  /// Giải phóng tài nguyên
  void dispose() {
    _flutterTts.stop();
    _isSpeaking = false;
    _isInitialized = false;
  }
}
