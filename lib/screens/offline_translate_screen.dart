import 'dart:async';

import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../services/hy_mt_translate_service.dart';
import '../services/stt_service.dart';
import '../services/translation_queue.dart';
import '../services/audio_stream_service.dart';
import 'dart:typed_data';
import 'dart:convert';

class _ChatMessage {
  final String source;
  final String translated;
  _ChatMessage({required this.source, required this.translated});
}

class OfflineTranslateScreen extends StatefulWidget {
  const OfflineTranslateScreen({super.key});

  @override
  State<OfflineTranslateScreen> createState() => _OfflineTranslateScreenState();
}

class _OfflineTranslateScreenState extends State<OfflineTranslateScreen>
    with TickerProviderStateMixin {
  final TtsService _ttsService = TtsService();
  final HyMtTranslateService _mtService = HyMtTranslateService();
  final SttService _sttService = SttService();
  late final TranslationQueue _translationQueue = TranslationQueue(_mtService);

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<_ChatMessage> _messages = [];

  String _sourceLang = "Deutsch";
  String _targetLang = "Tiếng Việt";
  bool _isRecording = false;
  bool _autoTts = true;

  bool _sttReady = false;
  bool _mtReady = false;
  bool _ttsReady = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  StreamSubscription<TranslationResult>? _resultSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Wire STT → TranslationQueue
    _sttService.onInterimText = (text) {
      print('📝 [Screen] onInterimText: "$text"');
      if (!mounted) return;
      setState(() {
        if (_messages.isNotEmpty && _messages.last.translated == '...') {
          _messages.last = _ChatMessage(source: text, translated: '...');
        } else {
          _messages.add(_ChatMessage(source: text, translated: '...'));
        }
      });
      _scrollToBottom();
    };

    _sttService.onTextRecognized = (text) {
      print('📝 [Screen] onTextRecognized → enqueue: "$text"');
      _translationQueue.enqueue(text, isFinal: true);
    };

    // Listen to translation results
    _resultSub = _translationQueue.results.listen((result) {
      if (!mounted) return;
      setState(() {
        _mtReady = !result.isError;
        // Find and update the matching message, or add new
        final idx = _messages.lastIndexWhere(
          (m) => m.source == result.source && m.translated == '...',
        );
        if (idx >= 0) {
          _messages[idx] = _ChatMessage(
            source: result.source,
            translated: result.translated,
          );
        } else {
          _messages.add(_ChatMessage(
            source: result.source,
            translated: result.translated,
          ));
        }
      });
      _scrollToBottom();

      if (_autoTts && !result.isError && _ttsReady) {
        _ttsService.speak(result.translated);
      }
    });

    _initializeServices();
  }

  String _getLangCode(String lang) {
    if (lang == "Deutsch") return "de";
    if (lang == "Tiếng Việt") return "vi";
    return "en";
  }

  Future<void> _initializeServices() async {
    try {
      await _ttsService.initialize();
      if (mounted) setState(() => _ttsReady = true);
    } catch (e) {
      debugPrint('[TTS] Init failed: $e');
    }

    try {
      await _sttService.initialize(_getLangCode(_sourceLang));
      if (mounted) setState(() => _sttReady = _sttService.isReady);
    } catch (e) {
      debugPrint('[STT] Init failed: $e');
    }

    try {
      await _mtService.initialize();
      if (mounted) setState(() => _mtReady = true);
    } catch (e) {
      if (mounted) setState(() => _mtReady = false);
      debugPrint('[MT] Init failed: $e');
    }

    _translationQueue.updateLanguages(
      sourceLanguage: _sourceLang,
      targetLanguage: _targetLang,
    );
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    _translationQueue.dispose();
    _pulseController.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _ttsService.dispose();
    _mtService.dispose();
    _sttService.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _processAudioChunk(String base64Chunk) async {
    if (!_sttReady) {
      print('⚠️ [Screen] _processAudioChunk: _sttReady=false, skipping');
      return;
    }

    try {
      final chunk = base64Decode(base64Chunk);

      final int16List = chunk.buffer.asInt16List(
        chunk.offsetInBytes,
        chunk.lengthInBytes ~/ 2,
      );
      final float32List = Float32List(int16List.length);
      for (int i = 0; i < int16List.length; i++) {
        float32List[i] = int16List[i] / 32768.0;
      }

      // Feed audio; callbacks handle interim text and queue enqueue
      _sttService.feedAudio(float32List);
    } catch (e) {
      debugPrint('STT Real-time Error: $e');
    }
  }

  void _submitManualText(String text) {
    if (text.trim().isEmpty) return;

    setState(() {
      _messages.add(_ChatMessage(source: text.trim(), translated: '...'));
    });
    _scrollToBottom();

    _translationQueue.enqueue(text.trim(), isFinal: true);
  }

  Future<void> _speakText(String text) async {
    if (text.isEmpty) return;
    await _ttsService.speak(text);
  }

  Future<void> _swapLanguages() async {
    if (_isRecording) {
      setState(() => _isRecording = false);
      await audioStreamService.stopStreaming();
      _sttService.stopStream();
    }

    setState(() {
      final temp = _sourceLang;
      _sourceLang = _targetLang;
      _targetLang = temp;
      _sttReady = false;
    });

    _translationQueue.updateLanguages(
      sourceLanguage: _sourceLang,
      targetLanguage: _targetLang,
    );

    try {
      await _sttService.initialize(_getLangCode(_sourceLang));
      if (mounted) {
        setState(() => _sttReady = _sttService.isReady);
      }
    } catch (e) {
      if (mounted) setState(() => _sttReady = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Offline Translate",
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        actions: [
          GestureDetector(
            onLongPress: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_autoTts ? 'Auto TTS: Bật' : 'Auto TTS: Tắt'),
                  duration: const Duration(seconds: 1),
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
              );
            },
            onTap: () => setState(() => _autoTts = !_autoTts),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                _autoTts
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                color: _autoTts
                    ? const Color(0xFF4CAF50)
                    : Colors.grey.shade600,
                size: 22,
              ),
            ),
          ),
          _buildStatusDot("STT", _sttReady, const Color(0xFF2196F3)),
          _buildStatusDot("MT", _mtReady, const Color(0xFFFF9800)),
          _buildStatusDot("TTS", _ttsReady, const Color(0xFF4CAF50)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildLanguageSelector(),
          Expanded(child: _buildChatArea()),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildStatusDot(String label, bool ready, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: "$label: ${ready ? 'Sẵn sàng' : 'Chưa sẵn sàng'}",
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ready ? color : Colors.grey.shade700,
            boxShadow: ready
                ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              _sourceLang,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          GestureDetector(
            onTap: _swapLanguages,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF00C853).withValues(alpha: 0.3),
                ),
              ),
              child: const Icon(
                Icons.swap_horiz_rounded,
                color: Color(0xFF00C853),
                size: 22,
              ),
            ),
          ),
          Expanded(
            child: Text(
              _targetLang,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatArea() {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                color: Colors.grey.shade800, size: 48),
            const SizedBox(height: 12),
            Text(
              "Bắt đầu nói hoặc nhập để dịch",
              style: TextStyle(color: Colors.grey.shade700, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return _buildMessagePair(msg);
      },
    );
  }

  Widget _buildMessagePair(_ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // You bubble
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A5F),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    "You",
                    style: TextStyle(
                      color: Colors.blue.shade300,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    msg.source,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // AITrans bubble
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D2818),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                border: Border.all(
                  color: const Color(0xFF00C853).withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "AITrans",
                        style: TextStyle(
                          color: Colors.green.shade300,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (msg.translated != '...')
                        GestureDetector(
                          onTap: () => _speakText(msg.translated),
                          child: Icon(
                            Icons.volume_up_rounded,
                            color: Colors.green.shade400,
                            size: 16,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  msg.translated == '...'
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.green.shade400,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Đang dịch...",
                              style: TextStyle(
                                color: Colors.green.shade400,
                                fontSize: 14,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        )
                      : Text(
                          msg.translated,
                          style: const TextStyle(
                            color: Color(0xFF69F0AE),
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          // Text input
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: TextField(
                controller: _inputController,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: "Nhập text...",
                  hintStyle: TextStyle(color: Colors.grey.shade700),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: (text) {
                  if (text.trim().isNotEmpty) {
                    _inputController.clear();
                    _submitManualText(text);
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Translate button
          GestureDetector(
            onTap: () {
              final text = _inputController.text;
              if (text.trim().isNotEmpty) {
                _inputController.clear();
                _submitManualText(text);
              }
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF00C853),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00C853).withValues(alpha: 0.3),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(Icons.translate_rounded,
                  color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 8),
          // Mic button
          GestureDetector(
            onTap: () async {
              if (_isRecording) {
                setState(() => _isRecording = false);
                await audioStreamService.stopStreaming();
                _sttService.stopStream();
              } else {
                if (!_sttReady) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'STT chưa sẵn sàng. Cần mô hình vào stt/${_getLangCode(_sourceLang)}',
                      ),
                      backgroundColor: Colors.red.shade900,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }

                setState(() => _isRecording = true);
                _sttService.startStream();

                await audioStreamService.startStreaming((base64Chunk) {
                  _processAudioChunk(base64Chunk);
                });
              }
            },
            child: ScaleTransition(
              scale: _isRecording
                  ? _pulseAnimation
                  : const AlwaysStoppedAnimation(1.0),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: _isRecording
                        ? [const Color(0xFFFF1744), const Color(0xFFD50000)]
                        : [const Color(0xFF455A64), const Color(0xFF37474F)],
                  ),
                  boxShadow: _isRecording
                      ? [
                          BoxShadow(
                            color: const Color(0xFFFF1744)
                                .withValues(alpha: 0.4),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: Icon(
                  _isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
