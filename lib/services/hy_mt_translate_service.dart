import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

class HyMtTranslateService {
  static const String defaultModelFileName = 'gemma-2-2b-it-Q4_K_M.gguf';

  HyMtTranslateService({this.modelFileName = defaultModelFileName});

  final String modelFileName;
  LlamaEngine? _engine;
  bool _isReady = false;
  Future<void>? _initFuture;

  bool get isReady => _isReady;

  Future<String> get expectedModelPath async {
    final supportDir = await getApplicationSupportDirectory();
    return '${supportDir.path}${Platform.pathSeparator}models${Platform.pathSeparator}$modelFileName';
  }

  Future<void> initialize() {
    if (_isReady) return Future.value();
    if (_initFuture != null) return _initFuture!;

    _initFuture = _doInitialize().whenComplete(() {
      _initFuture = null;
    });
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    try {
      final modelPath = await expectedModelPath;
      await _validateModelFile(modelPath);

      // Try GPU/Vulkan first, then CPU. Some Android devices fail while
      // creating GPU context for very low-bit GGUF files.
      try {
        await _loadModel(
          modelPath,
          const ModelParams(
            contextSize: 2048,
            gpuLayers: ModelParams.maxGpuLayers,
            preferredBackend: GpuBackend.vulkan,
          ),
        );
      } catch (gpuError) {
        await _disposeEngine();
        try {
          await _loadModel(
            modelPath,
            const ModelParams(
              contextSize: 1024,
              gpuLayers: 0,
              preferredBackend: GpuBackend.cpu,
              batchSize: 128,
              microBatchSize: 128,
            ),
          );
        } catch (cpuError) {
          throw HyMtModelLoadException(
            modelPath: modelPath,
            message: 'Qwen3.5 model exists but cannot be loaded.',
            details: 'GPU load failed: $gpuError\nCPU fallback failed: $cpuError',
          );
        }
      }

      _isReady = true;
    } catch (_) {
      _isReady = false;
      rethrow;
    }
  }

  Future<String> translate({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (!_isReady) {
      await initialize();
    }

    final engine = _engine;
    if (engine == null) {
      throw StateError('Qwen3.5 engine is not initialized.');
    }

    final prompt = _buildPrompt(
      text: text,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );
    final buffer = StringBuffer();

    await for (final chunk in engine.create(
      [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text:
              'You are an expert, concise offline translator. Translate the given text to the target language. Output ONLY the translated text without any prefix, quotes, or explanations.',
        ),
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
      ],
      params: const GenerationParams(
        maxTokens: 512,
        temp: 0.1,
        topK: 1,
        topP: 0.9,
        penalty: 1.0,
        //stopSequences: ['</translation>', '<|im_end|>'],
        stopSequences: ['<eos>'],
      ),
    )) {
      for (final choice in chunk.choices) {
        final content = choice.delta.content;
        if (content != null) buffer.write(content);
      }
    }

    return _cleanOutput(buffer.toString());
  }

  Future<void> dispose() => _disposeEngine();

  Future<void> _loadModel(String modelPath, ModelParams params) async {
    final engine = LlamaEngine(LlamaBackend());
    await engine.setDartLogLevel(LlamaLogLevel.none);
    await engine.setNativeLogLevel(LlamaLogLevel.info);
    await engine.loadModel(modelPath, modelParams: params);
    _engine = engine;
  }

  Future<void> _disposeEngine() async {
    final engine = _engine;
    _engine = null;
    _isReady = false;
    await engine?.dispose();
  }

  Future<void> _validateModelFile(String modelPath) async {
    final modelFile = File(modelPath);
    if (!await modelFile.exists()) {
      throw FileSystemException(
        'Qwen3.5 model file was not found.',
        modelPath,
      );
    }

    final length = await modelFile.length();
    if (length < 16) {
      throw HyMtModelLoadException(
        modelPath: modelPath,
        message: 'Qwen3.5 model file is empty or incomplete.',
        details: 'File size: $length bytes',
      );
    }

    final header = await modelFile.openRead(0, 4).first;
    final signature = String.fromCharCodes(header);
    if (signature != 'GGUF') {
      throw HyMtModelLoadException(
        modelPath: modelPath,
        message: 'Qwen3.5 model is not a valid GGUF file.',
        details: 'Header is "$signature", expected "GGUF".',
      );
    }
  }

  String _buildPrompt({
    required String text,
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    return '''Translate from $sourceLanguage to $targetLanguage.
Return only the translation, without explanations or quotes.

Source:
$text

Translation:''';
  }

  String _cleanOutput(String value) {
    var output = value.trim();
    const prefixes = ['Translation:', 'Bản dịch:', 'Dịch:'];
    for (final prefix in prefixes) {
      if (output.toLowerCase().startsWith(prefix.toLowerCase())) {
        output = output.substring(prefix.length).trim();
      }
    }
    return output;
  }
}

class HyMtModelLoadException implements Exception {
  HyMtModelLoadException({
    required this.modelPath,
    required this.message,
    required this.details,
  });

  final String modelPath;
  final String message;
  final String details;

  @override
  String toString() => '$message\nPath: $modelPath\n$details';
}
