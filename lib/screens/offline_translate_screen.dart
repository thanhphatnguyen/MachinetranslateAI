import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../services/hy_mt_translate_service.dart';
import '../services/stt_service.dart';
import '../services/audio_stream_service.dart';
import 'dart:typed_data';
import 'dart:convert';

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
  final TextEditingController _inputController = TextEditingController();

  String _sourceText = "";
  String _translatedText = "";
  String _sourceLang = "Deutsch";
  String _targetLang = "Tiếng Việt";
  bool _isRecording = false;
  bool _isTranslating = false;
  bool _isSpeaking = false;

  // Status cho các model
  bool _sttReady = false;
  bool _mtReady = false;
  bool _ttsReady = false;
  String _mtStatus = 'Qwen3.5 not initialized';

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

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
    _initializeServices();
  }

  String _getLangCode(String lang) {
    if (lang == "Deutsch") return "de";
    if (lang == "Tiếng Việt") return "vi";
    return "en"; // Default fallback
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
      if (mounted) {
        setState(() {
          _mtReady = true;
          _mtStatus = 'Qwen3.5 ready';
        });
      }
    } catch (e) {
      final modelPath = await _mtService.expectedModelPath;
      if (mounted) {
        setState(() {
          _mtReady = false;
          _mtStatus = 'Qwen3.5 init error: $e';
        });
      }
      debugPrint('[Qwen3.5] Init failed: $e');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _inputController.dispose();
    _ttsService.dispose();
    _mtService.dispose();
    _sttService.dispose();
    super.dispose();
  }

  Future<void> _processAudioChunk(String base64Chunk) async {
    if (!_sttReady) return;

    try {
      final chunk = base64Decode(base64Chunk);
      
      // Chuyển 16-bit PCM (Int16) sang Float32List (-1.0 -> 1.0)
      final int16List = chunk.buffer.asInt16List(chunk.offsetInBytes, chunk.lengthInBytes ~/ 2);
      final float32List = Float32List(int16List.length);
      for (int i = 0; i < int16List.length; i++) {
        float32List[i] = int16List[i] / 32768.0;
      }

      // Đưa vào STT để giải mã realtime
      final text = _sttService.feedAudioAndRecognize(float32List);
      
      if (text.isNotEmpty && text != _sourceText) {
        setState(() {
          _sourceText = text;
        });
      }

      // Kiểm tra Endpoint (Người dùng vừa dứt câu)
      if (_sttService.isEndpoint()) {
        final finalText = text;
        _sttService.resetStream(); // Chuẩn bị nhận diện câu tiếp theo
        
        if (finalText.trim().isNotEmpty) {
           _translateText(finalText); // Dịch câu vừa nói xong
        }
      }
    } catch (e) {
      debugPrint('STT Real-time Error: $e');
    }
  }

  /// Xử lý dịch text (Phase 1: giả lập, Phase 3: dùng Qwen3.5)
  Future<void> _translateText(String text) async {
    if (text.trim().isEmpty) return;

    setState(() {
      _sourceText = text;
      _isTranslating = true;
      _translatedText = '';
    });

    try {
      final result = await _mtService.translate(
        text: text,
        sourceLanguage: _sourceLang,
        targetLanguage: _targetLang,
      );
      if (!mounted) return;
      setState(() {
        _mtReady = true;
        _mtStatus = 'Qwen3.5 ready';
        _translatedText = result.isEmpty
            ? '[Qwen3.5 returned empty output]'
            : result;
        _isTranslating = false;
      });
    } catch (e) {
      final modelPath = await _mtService.expectedModelPath;
      if (!mounted) return;
      setState(() {
        _mtReady = false;
        _mtStatus = 'Qwen3.5 error: $e';
        _translatedText = 'Cannot translate with Qwen3.5.\n\n'
            'Model path:\n$modelPath\n\n'
            'Error:\n$e';
        _isTranslating = false;
      });
    }
  }

  /// Phát TTS cho text đã dịch
  Future<void> _speakTranslation() async {
    if (_translatedText.isEmpty) return;
    setState(() => _isSpeaking = true);
    await _ttsService.speak(_translatedText);
    setState(() => _isSpeaking = false);
  }

  /// Hoán đổi ngôn ngữ
  Future<void> _swapLanguages() async {
    if (_isRecording) {
      // Dừng thu âm nếu đang thu
      setState(() => _isRecording = false);
      await audioStreamService.stopStreaming();
      _sttService.stopStream();
    }

    setState(() {
      final temp = _sourceLang;
      _sourceLang = _targetLang;
      _targetLang = temp;
      
      _sttReady = false;
      _sourceText = 'Đang chuyển mô hình STT...';
    });

    try {
      await _sttService.initialize(_getLangCode(_sourceLang));
      if (mounted) {
        setState(() {
          _sttReady = _sttService.isReady;
          _sourceText = _sttReady ? '' : 'Không tìm thấy mô hình STT trong thư mục stt/${_getLangCode(_sourceLang)}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
           _sttReady = false;
           _sourceText = 'Lỗi nạp mô hình STT: $e';
        });
      }
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
          // Status indicators
          _buildStatusDot("STT", _sttReady, const Color(0xFF2196F3)),
          _buildStatusDot("MT", _mtReady, const Color(0xFFFF9800)),
          _buildStatusDot("TTS", _ttsReady, const Color(0xFF4CAF50)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // === Language Selector ===
          _buildLanguageSelector(),

          const SizedBox(height: 8),

          // === Source Text Area ===
          Expanded(
            flex: 3,
            child: _buildSourceArea(),
          ),

          // === Translate Button ===
          _buildTranslateButton(),

          // === Translated Text Area ===
          Expanded(
            flex: 3,
            child: _buildTranslatedArea(),
          ),

          // === Bottom Controls ===
          _buildBottomControls(),
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
          // Source Language
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

          // Swap button
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

          // Target Language
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

  Widget _buildSourceArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_rounded,
                  color: Colors.grey.shade500, size: 18),
              const SizedBox(width: 6),
              Text(
                _sourceLang,
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (_sourceText.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _sourceText = "";
                      _translatedText = "";
                      _inputController.clear();
                    });
                  },
                  child: Icon(Icons.close_rounded,
                      color: Colors.grey.shade600, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _sourceText.isEmpty
                ? TextField(
                    controller: _inputController,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                    decoration: InputDecoration(
                      hintText: "Nhập hoặc nói text để dịch...",
                      hintStyle: TextStyle(color: Colors.grey.shade700),
                      border: InputBorder.none,
                    ),
                  )
                : SingleChildScrollView(
                    child: Text(
                      _sourceText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        height: 1.5,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranslateButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00C853),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            elevation: 0,
          ),
          onPressed: _isTranslating
              ? null
              : () {
                  final text = _sourceText.isNotEmpty
                      ? _sourceText
                      : _inputController.text;
                  _translateText(text);
                },
          child: _isTranslating
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.translate_rounded,
                        color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      "DỊCH",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildTranslatedArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B0E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF00C853).withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.volume_up_rounded,
                  color: const Color(0xFF00C853).withValues(alpha: 0.7),
                  size: 18),
              const SizedBox(width: 6),
              Text(
                _targetLang,
                style: TextStyle(
                  color: const Color(0xFF00C853).withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (_translatedText.isNotEmpty)
                GestureDetector(
                  onTap: _speakTranslation,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C853).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _isSpeaking
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                      color: const Color(0xFF00C853),
                      size: 18,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _translatedText.isEmpty
                ? Center(
                    child: Text(
                      "Bản dịch sẽ hiển thị ở đây",
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 15,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Text(
                      _translatedText,
                      style: const TextStyle(
                        color: Color(0xFF69F0AE),
                        fontSize: 18,
                        height: 1.5,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Tap-to-Talk button
          GestureDetector(
            onTap: () async {
              if (_isRecording) {
                // Tắt thu âm
                setState(() => _isRecording = false);
                await audioStreamService.stopStreaming();
                _sttService.stopStream();
              } else {
                if (!_sttReady) {
                   setState(() => _sourceText = 'STT chưa sẵn sàng. Cần tải mô hình Online Zipformer vào thư mục stt/${_getLangCode(_sourceLang)}');
                   return;
                }
                
                // Bật thu âm
                setState(() {
                  _isRecording = true;
                  _sourceText = 'Đang nghe...';
                });
                
                _sttService.startStream();
                
                await audioStreamService.startStreaming((base64Chunk) {
                  _processAudioChunk(base64Chunk);
                });
              }
            },
            child: ScaleTransition(
              scale: _isRecording ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
              child: Container(
                width: 72,
                height: 72,
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
                            color: const Color(0xFFFF1744).withValues(alpha: 0.4),
                            blurRadius: 20,
                            spreadRadius: 4,
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 10,
                          ),
                        ],
                ),
                child: Icon(
                  _isRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
