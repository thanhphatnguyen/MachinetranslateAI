import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

typedef TextCallback = void Function(String text);

class SttService {
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _activeStream;
  bool _isReady = false;
  String _currentLangCode = '';

  /// Called when STT endpoint detected (final recognized text).
  TextCallback? onTextRecognized;

  /// Called on each audio feed with interim (partial) text.
  TextCallback? onInterimText;

  bool get isReady => _isReady;

  Future<void> initialize(String langCode) async {
    if (_isReady && _currentLangCode == langCode) return;

    // Preserve callbacks across re-init
    final savedOnInterim = onInterimText;
    final savedOnRecognized = onTextRecognized;

    if (_isReady) {
      _releaseModel();
      _isReady = false;
    }

    onInterimText = savedOnInterim;
    onTextRecognized = savedOnRecognized;

    sherpa.initBindings();

    final supportDir = await getApplicationSupportDirectory();
    final modelDir =
        '${supportDir.path}${Platform.pathSeparator}models${Platform.pathSeparator}stt${Platform.pathSeparator}$langCode';

    final encoderFile = File('$modelDir${Platform.pathSeparator}encoder.onnx');
    final decoderFile = File('$modelDir${Platform.pathSeparator}decoder.onnx');
    final joinerFile = File('$modelDir${Platform.pathSeparator}joiner.onnx');
    final tokensFile = File('$modelDir${Platform.pathSeparator}tokens.txt');

    if (!await encoderFile.exists() ||
        !await decoderFile.exists() ||
        !await joinerFile.exists() ||
        !await tokensFile.exists()) {
      print('❌ [STT] Model files not found at $modelDir');
      return;
    }

    try {
      final config = sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: encoderFile.path,
            decoder: decoderFile.path,
            joiner: joinerFile.path,
          ),
          tokens: tokensFile.path,
          modelType: 'zipformer2',
          numThreads: 2,
        ),
        feat: sherpa.FeatureConfig(
          sampleRate: 16000,
          featureDim: 80,
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.0,
        rule2MinTrailingSilence: 1.0,
        rule3MinUtteranceLength: 20.0,
      );

      _recognizer = sherpa.OnlineRecognizer(config);
      _isReady = true;
      _currentLangCode = langCode;
      print('✅ [STT] Sherpa-ONNX initialized for $langCode');
    } catch (e) {
      print('❌ [STT] Init failed: $e');
    }
  }

  void startStream() {
    if (!_isReady || _recognizer == null) {
      throw StateError('STT engine is not initialized.');
    }
    _activeStream?.free();
    _activeStream = _recognizer!.createStream();
  }

  void stopStream() {
    _activeStream?.free();
    _activeStream = null;
  }

  /// Feed audio samples and trigger callbacks.
  /// - [onInterimText] called with partial recognition result.
  /// - [onTextRecognized] called when endpoint detected (utterance complete).
  /// Returns the current interim text.
  String feedAudio(Float32List samples) {
    if (_activeStream == null || _recognizer == null) return "";

    _activeStream!.acceptWaveform(samples: samples, sampleRate: 16000);

    while (_recognizer!.isReady(_activeStream!)) {
      _recognizer!.decode(_activeStream!);
    }

    final result = _recognizer!.getResult(_activeStream!);
    final text = result.text;

    if (text.isNotEmpty) {
      print('🎤 [STT] interim: "$text"');
      onInterimText?.call(text);
    }

    if (_recognizer!.isEndpoint(_activeStream!)) {
      if (text.trim().isNotEmpty) {
        print('🎤 [STT] endpoint → "$text"');
        onTextRecognized?.call(text.trim());
      }
      _recognizer!.reset(_activeStream!);
    }

    return text;
  }

  void _releaseModel() {
    _activeStream?.free();
    _recognizer?.free();
    _activeStream = null;
    _recognizer = null;
  }

  void dispose() {
    _releaseModel();
    _isReady = false;
    _currentLangCode = '';
    onTextRecognized = null;
    onInterimText = null;
  }
}
