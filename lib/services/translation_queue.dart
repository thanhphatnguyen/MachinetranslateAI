import 'dart:async';
import 'dart:collection';

import 'hy_mt_translate_service.dart';

class TranslationResult {
  final String source;
  final String translated;
  final String sourceLanguage;
  final String targetLanguage;
  final bool isError;

  const TranslationResult({
    required this.source,
    required this.translated,
    required this.sourceLanguage,
    required this.targetLanguage,
    this.isError = false,
  });

  factory TranslationResult.error({
    required String source,
    required String message,
    required String sourceLanguage,
    required String targetLanguage,
  }) =>
      TranslationResult(
        source: source,
        translated: message,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        isError: true,
      );
}

class TranslationQueue {
  TranslationQueue(this._mtService);

  final HyMtTranslateService _mtService;

  final Queue<_QueueItem> _queue = Queue();
  final StreamController<TranslationResult> _resultController =
      StreamController<TranslationResult>.broadcast();

  bool _processing = false;
  bool _disposed = false;

  String _sourceLanguage = 'Deutsch';
  String _targetLanguage = 'Tiếng Việt';

  Stream<TranslationResult> get results => _resultController.stream;
  bool get isProcessing => _processing;
  int get pendingCount => _queue.length;

  void updateLanguages({
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    _sourceLanguage = sourceLanguage;
    _targetLanguage = targetLanguage;
  }

  /// Add text to the translation queue.
  /// [isFinal] = true when STT endpoint detected or manual input.
  /// [isFinal] = false for interim STT results (will be deduped/replaced).
  void enqueue(String text, {bool isFinal = true}) {
    if (_disposed || text.trim().isEmpty) return;

    if (!isFinal) {
      // Replace the last interim item (STT interim results update rapidly)
      if (_queue.isNotEmpty && !_queue.last.isFinal) {
        _queue.removeLast();
      }
    }

    _queue.add(_QueueItem(
      text: text.trim(),
      sourceLanguage: _sourceLanguage,
      targetLanguage: _targetLanguage,
      isFinal: isFinal,
    ));

    _processNext();
  }

  Future<void> _processNext() async {
    if (_processing || _queue.isEmpty || _disposed) return;

    _processing = true;

    while (_queue.isNotEmpty && !_disposed) {
      final item = _queue.removeFirst();

      // Skip interim items if more items are queued (STT keeps updating)
      if (!item.isFinal && _queue.isNotEmpty) continue;

      try {
        final translated = await _mtService.translate(
          text: item.text,
          sourceLanguage: item.sourceLanguage,
          targetLanguage: item.targetLanguage,
        );

        if (_disposed) return;

        _resultController.add(TranslationResult(
          source: item.text,
          translated: translated.isEmpty ? '[empty output]' : translated,
          sourceLanguage: item.sourceLanguage,
          targetLanguage: item.targetLanguage,
        ));
      } catch (e) {
        if (_disposed) return;

        String errorMsg;
        try {
          final modelPath = await _mtService.expectedModelPath;
          errorMsg = 'Error: $e\nModel: $modelPath';
        } catch (_) {
          errorMsg = 'Error: $e';
        }

        _resultController.add(TranslationResult.error(
          source: item.text,
          message: errorMsg,
          sourceLanguage: item.sourceLanguage,
          targetLanguage: item.targetLanguage,
        ));
      }
    }

    _processing = false;
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _resultController.close();
  }
}

class _QueueItem {
  final String text;
  final String sourceLanguage;
  final String targetLanguage;
  final bool isFinal;

  const _QueueItem({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.isFinal,
  });
}
