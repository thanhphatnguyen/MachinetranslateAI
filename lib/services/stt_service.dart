import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

typedef TextCallback = void Function(String text);

class SttService {
  final SpeechToText _speech = SpeechToText();
  bool _isReady = false;
  bool _isListening = false;
  bool _shouldContinue = false;
  String _currentLangCode = '';

  TextCallback? onTextRecognized;
  TextCallback? onInterimText;
  TextCallback? onError;

  bool get isReady => _isReady;
  bool get isListening => _isListening;

  Future<void> initialize(String langCode) async {
    if (_isReady && _currentLangCode == langCode) return;

    final savedOnInterim = onInterimText;
    final savedOnRecognized = onTextRecognized;
    final savedOnError = onError;

    if (_isReady) {
      _shouldContinue = false;
      await _speech.stop();
      _isReady = false;
    }

    onInterimText = savedOnInterim;
    onTextRecognized = savedOnRecognized;
    onError = savedOnError;

    try {
      _isReady = await _speech.initialize(
        onError: (error) {
          print('ℹ️ [STT] Error: ${error.errorMsg}');
          _isListening = false;

          if (error.errorMsg == 'error_no_match') {
            onError?.call('Không nhận dạng được. Thử nói rõ hơn.');
          } else if (error.errorMsg == 'error_speech_timeout') {
            onError?.call('Hết thời gian chờ.');
          }

          // Auto restart if should continue
          if (_shouldContinue) {
            Future.delayed(const Duration(milliseconds: 300), () {
              if (_shouldContinue) _restartListening();
            });
          }
        },
        onStatus: (status) {
          print('ℹ️ [STT] Status: $status');

          if (status == 'done' || status == 'notListening') {
            _isListening = false;

            // Auto restart if should continue
            if (_shouldContinue) {
              Future.delayed(const Duration(milliseconds: 200), () {
                if (_shouldContinue) _restartListening();
              });
            }
          }
        },
      );

      if (_isReady) {
        _currentLangCode = langCode;
        print('✅ [STT] Speech-to-Text initialized for $langCode');
      } else {
        print('❌ [STT] Failed to initialize');
      }
    } catch (e) {
      print('❌ [STT] Init failed: $e');
      _isReady = false;
    }
  }

  Future<void> _restartListening() async {
    if (!_isReady || !_shouldContinue) return;

    try {
      final localeId = _getLocaleId(_currentLangCode);

      await _speech.listen(
        onResult: _onSpeechResult,
        localeId: localeId,
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        pauseFor: const Duration(seconds: 5),
      );

      _isListening = true;
      print('🎤 [STT] Listening restarted');
    } catch (e) {
      print('❌ [STT] Restart failed: $e');
    }
  }

  Future<void> startStream() async {
    if (!_isReady) {
      throw StateError('STT engine is not initialized.');
    }

    _shouldContinue = true;
    final localeId = _getLocaleId(_currentLangCode);

    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: localeId,
      listenMode: ListenMode.dictation,
      partialResults: true,
      cancelOnError: false,
      pauseFor: const Duration(seconds: 5),
    );

    _isListening = true;
    print('🎤 [STT] Listening started ($localeId)');
  }

  Future<void> stopStream() async {
    _shouldContinue = false;
    await _speech.stop();
    _isListening = false;
    print('🎤 [STT] Listening stopped');
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords;

    if (text.isEmpty) return;

    if (result.finalResult) {
      print('🎤 [STT] final: "$text"');
      onTextRecognized?.call(text);
    } else {
      print('🎤 [STT] interim: "$text"');
      onInterimText?.call(text);
    }
  }

  String _getLocaleId(String langCode) {
    switch (langCode) {
      case 'de':
        return 'de_DE';
      case 'vi':
        return 'vi_VN';
      case 'en':
        return 'en_US';
      default:
        return 'vi_VN';
    }
  }

  Future<void> dispose() async {
    _shouldContinue = false;
    await _speech.stop();
    _speech.cancel();
    _isReady = false;
    _isListening = false;
    _currentLangCode = '';
    onTextRecognized = null;
    onInterimText = null;
    onError = null;
  }
}
