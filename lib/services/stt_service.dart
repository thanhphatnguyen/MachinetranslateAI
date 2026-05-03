import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class SttService {
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _activeStream;
  bool _isReady = false;
  String _currentLangCode = '';

  bool get isReady => _isReady;

  Future<void> initialize(String langCode) async {
    if (_isReady && _currentLangCode == langCode) return;

    // Nếu đổi ngôn ngữ, giải phóng model cũ trước
    if (_isReady) {
      dispose();
      _isReady = false;
    }

    sherpa.initBindings();

    final supportDir = await getApplicationSupportDirectory();
    final modelDir = '${supportDir.path}${Platform.pathSeparator}models${Platform.pathSeparator}stt${Platform.pathSeparator}$langCode';

    final encoderFile = File('$modelDir${Platform.pathSeparator}encoder.onnx');
    final decoderFile = File('$modelDir${Platform.pathSeparator}decoder.onnx');
    final joinerFile = File('$modelDir${Platform.pathSeparator}joiner.onnx');
    final tokensFile = File('$modelDir${Platform.pathSeparator}tokens.txt');

    if (!await encoderFile.exists() || !await decoderFile.exists() || !await joinerFile.exists() || !await tokensFile.exists()) {
      print('❌ [STT] Không tìm thấy đủ 4 file mô hình STT Online Zipformer tại $modelDir');
      print('   Cần: encoder.onnx, decoder.onnx, joiner.onnx, tokens.txt');
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
      print('✅ [STT] Sherpa-ONNX STT (Online Zipformer - $langCode) đã khởi tạo thành công.');
    } catch (e) {
      print('❌ [STT] Lỗi khi nạp mô hình: $e');
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

  String feedAudioAndRecognize(Float32List samples) {
    if (_activeStream == null || _recognizer == null) return "";

    _activeStream!.acceptWaveform(samples: samples, sampleRate: 16000);
    
    while (_recognizer!.isReady(_activeStream!)) {
      _recognizer!.decode(_activeStream!);
    }
    
    final result = _recognizer!.getResult(_activeStream!);
    return result.text;
  }

  bool isEndpoint() {
    if (_activeStream == null || _recognizer == null) return false;
    return _recognizer!.isEndpoint(_activeStream!);
  }

  void resetStream() {
    if (_activeStream == null || _recognizer == null) return;
    _recognizer!.reset(_activeStream!);
  }

  void dispose() {
    _activeStream?.free();
    _recognizer?.free();
    _activeStream = null;
    _recognizer = null;
    _isReady = false;
    _currentLangCode = '';
  }
}
