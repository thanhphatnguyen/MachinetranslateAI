import 'package:google_mlkit_translation/google_mlkit_translation.dart';

typedef ProgressCallback = void Function(String status, double progress);

class MtService {
  OnDeviceTranslator? _translator;
  final OnDeviceTranslatorModelManager _modelManager = OnDeviceTranslatorModelManager();
  bool _isReady = false;
  String _sourceLang = '';
  String _targetLang = '';

  bool get isReady => _isReady;

  Future<bool> isModelDownloaded(String langCode) async {
    try {
      return await _modelManager.isModelDownloaded(langCode);
    } catch (e) {
      print('❌ [MT] Check model failed: $e');
      return false;
    }
  }

  Future<bool> downloadModel(String langCode, {ProgressCallback? onProgress}) async {
    try {
      onProgress?.call('Đang tải model $langCode...', 0.0);

      final result = await _modelManager.downloadModel(langCode);

      if (result) {
        onProgress?.call('Tải xong model $langCode', 1.0);
        print('✅ [MT] Model downloaded: $langCode');
      } else {
        onProgress?.call('Tải thất bại: $langCode', -1.0);
        print('❌ [MT] Model download failed: $langCode');
      }

      return result;
    } catch (e) {
      onProgress?.call('Lỗi tải model: $e', -1.0);
      print('❌ [MT] Download error: $e');
      return false;
    }
  }

  Future<void> ensureModelsDownloaded(
    List<String> langCodes, {
    ProgressCallback? onProgress,
  }) async {
    final total = langCodes.length;
    var completed = 0;

    for (final langCode in langCodes) {
      final isDownloaded = await isModelDownloaded(langCode);

      if (isDownloaded) {
        completed++;
        onProgress?.call('Model $langCode đã có', completed / total);
        continue;
      }

      onProgress?.call('Đang tải model $langCode...', completed / total);
      final success = await downloadModel(langCode);
      completed++;

      if (success) {
        onProgress?.call('Tải xong $langCode ($completed/$total)', completed / total);
      } else {
        onProgress?.call('Lỗi tải $langCode', completed / total);
      }
    }

    onProgress?.call('Hoàn tất!', 1.0);
  }

  Future<void> initialize(String sourceLangCode, String targetLangCode) async {
    if (_isReady && _sourceLang == sourceLangCode && _targetLang == targetLangCode) {
      return;
    }

    // Close existing translator
    if (_translator != null) {
      _translator!.close();
      _translator = null;
      _isReady = false;
    }

    try {
      final sourceLanguage = _getTranslateLanguage(sourceLangCode);
      final targetLanguage = _getTranslateLanguage(targetLangCode);

      _translator = OnDeviceTranslator(
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );

      _sourceLang = sourceLangCode;
      _targetLang = targetLangCode;
      _isReady = true;

      print('✅ [MT] ML Kit Translation initialized: $sourceLangCode → $targetLangCode');
    } catch (e) {
      print('❌ [MT] Init failed: $e');
      _isReady = false;
    }
  }

  Future<String> translate(String text) async {
    if (!_isReady || _translator == null) {
      print('⚠️ [MT] Not ready, returning original text');
      return text;
    }

    if (text.trim().isEmpty) return text;

    try {
      final result = await _translator!.translateText(text);
      print('✅ [MT] "$text" → "$result"');
      return result;
    } catch (e) {
      print('❌ [MT] Translation failed: $e');
      return text;
    }
  }

  TranslateLanguage _getTranslateLanguage(String langCode) {
    switch (langCode) {
      case 'vi':
        return TranslateLanguage.vietnamese;
      case 'en':
        return TranslateLanguage.english;
      case 'de':
        return TranslateLanguage.german;
      case 'fr':
        return TranslateLanguage.french;
      case 'ja':
        return TranslateLanguage.japanese;
      case 'ko':
        return TranslateLanguage.korean;
      case 'zh':
        return TranslateLanguage.chinese;
      case 'es':
        return TranslateLanguage.spanish;
      default:
        return TranslateLanguage.english;
    }
  }

  Future<void> dispose() async {
    if (_translator != null) {
      _translator!.close();
      _translator = null;
    }
    _isReady = false;
    _sourceLang = '';
    _targetLang = '';
  }
}
