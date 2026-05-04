import 'dart:async';
import 'package:flutter/material.dart';
import '../services/stt_service.dart';

class _ChatMessage {
  final String text;
  final bool isFinal;
  _ChatMessage({required this.text, this.isFinal = true});
}

class OfflineTranslateScreen extends StatefulWidget {
  const OfflineTranslateScreen({super.key});

  @override
  State<OfflineTranslateScreen> createState() => _OfflineTranslateScreenState();
}

class _OfflineTranslateScreenState extends State<OfflineTranslateScreen>
    with TickerProviderStateMixin {
  final SttService _sttService = SttService();

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<_ChatMessage> _messages = [];

  static const List<Map<String, String>> _languages = [
    {'name': 'Tiếng Việt', 'code': 'vi', 'flag': '🇻🇳'},
    {'name': 'English', 'code': 'en', 'flag': '🇬🇧'},
    {'name': 'Deutsch', 'code': 'de', 'flag': '🇩🇪'},
  ];

  String _sourceLang = "Tiếng Việt";
  bool _isRecording = false;
  String? _errorMessage;

  bool _sttReady = false;

  // Debounce & dedup for interim
  Timer? _interimDebounce;
  String _lastInterimText = '';
  DateTime _lastInterimUpdate = DateTime.now();

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

    _setupSttCallbacks();
    _initializeServices();
  }

  void _setupSttCallbacks() {
    // Interim: debounce 150ms + skip duplicate
    _sttService.onInterimText = (text) {
      if (!mounted) return;

      // Skip duplicate
      if (text == _lastInterimText) return;
      _lastInterimText = text;

      // Debounce
      _interimDebounce?.cancel();
      _interimDebounce = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;

        // Rate limit: max 1 update per 100ms
        final now = DateTime.now();
        if (now.difference(_lastInterimUpdate).inMilliseconds < 100) return;
        _lastInterimUpdate = now;

        setState(() {
          _errorMessage = null;
          // Update or add interim message
          final interimIdx = _messages.lastIndexWhere((m) => !m.isFinal);
          if (interimIdx >= 0) {
            _messages[interimIdx] = _ChatMessage(text: text, isFinal: false);
          } else {
            _messages.add(_ChatMessage(text: text, isFinal: false));
          }
        });
        _scrollToBottom();
      });
    };

    // Final: add to messages list
    _sttService.onTextRecognized = (text) {
      if (!mounted) return;
      _interimDebounce?.cancel();
      _lastInterimText = '';

      setState(() {
        _errorMessage = null;
        // Remove interim message
        _messages.removeWhere((m) => !m.isFinal);
        // Add final message
        _messages.add(_ChatMessage(text: text, isFinal: true));
      });
      _scrollToBottom();
    };

    // Error handler
    _sttService.onError = (error) {
      if (!mounted) return;
      _interimDebounce?.cancel();
      setState(() {
        _isRecording = _sttService.isListening;
        _errorMessage = error;
      });
    };
  }

  String _getLangCode(String lang) {
    final found = _languages.firstWhere(
      (l) => l['name'] == lang,
      orElse: () => _languages[0],
    );
    return found['code']!;
  }

  Future<void> _initializeServices() async {
    try {
      await _sttService.initialize(_getLangCode(_sourceLang));
      if (mounted) setState(() => _sttReady = _sttService.isReady);
    } catch (e) {
      debugPrint('[STT] Init failed: $e');
    }
  }

  @override
  void dispose() {
    _interimDebounce?.cancel();
    _pulseController.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _sttService.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _submitManualText(String text) {
    if (text.trim().isEmpty) return;

    setState(() {
      _messages.add(_ChatMessage(text: text.trim(), isFinal: true));
    });
    _scrollToBottom();
  }

  Future<void> _changeLanguage(String lang) async {
    if (_sourceLang == lang) return;

    if (_isRecording) {
      setState(() => _isRecording = false);
      await _sttService.stopStream();
    }

    setState(() {
      _sourceLang = lang;
      _sttReady = false;
      _errorMessage = null;
    });

    await _sttService.initialize(_getLangCode(_sourceLang));
    if (mounted) setState(() => _sttReady = _sttService.isReady);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      setState(() => _isRecording = false);
      await _sttService.stopStream();
    } else {
      if (!_sttReady) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('STT chưa sẵn sàng.'),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }

      setState(() {
        _isRecording = true;
        _errorMessage = null;
        _lastInterimText = '';
      });
      await _sttService.startStream();
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
          "STT Transcript",
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        actions: [
          _buildStatusDot("STT", _sttReady, const Color(0xFF2196F3)),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: _languages.map((lang) {
          final isSelected = _sourceLang == lang['name'];
          return Expanded(
            child: GestureDetector(
              onTap: () => _changeLanguage(lang['name']!),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF2196F3).withValues(alpha: 0.2)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF2196F3)
                        : Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Column(
                  children: [
                    Text(lang['flag']!, style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 4),
                    Text(
                      lang['name']!,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.grey.shade500,
                        fontSize: 11,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildChatArea() {
    if (_messages.isEmpty && _errorMessage == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _sttReady ? Icons.mic_rounded : Icons.mic_off_rounded,
              color:
                  _sttReady ? const Color(0xFF2196F3) : Colors.grey.shade800,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              _sttReady
                  ? "Sẵn sàng ghi âm\nNhấn mic để bắt đầu"
                  : "Đang khởi tạo STT...",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _sttReady ? Colors.white70 : Colors.grey.shade600,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            if (!_sttReady) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  await _sttService.initialize(_getLangCode(_sourceLang));
                  if (mounted) {
                    setState(() => _sttReady = _sttService.isReady);
                  }
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text("Thử lại"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2196F3),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length + (_errorMessage != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (_errorMessage != null && index == 0) {
          return _buildErrorBubble(_errorMessage!);
        }
        final msgIndex = _errorMessage != null ? index - 1 : index;
        final msg = _messages[msgIndex];
        return msg.isFinal
            ? _buildFinalMessage(msg)
            : _buildInterimMessage(msg);
      },
    );
  }

  Widget _buildErrorBubble(String error) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.red.shade900.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.red.shade800),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_rounded, color: Colors.red.shade300, size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  error,
                  style: TextStyle(color: Colors.red.shade200, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInterimMessage(_ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E3A5F).withValues(alpha: 0.5),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  msg.text,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 15,
                    height: 1.4,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.blue.shade300,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFinalMessage(_ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Align(
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
          child: Text(
            msg.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.4,
            ),
          ),
        ),
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
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: TextField(
                controller: _inputController,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: "Nhập text hoặc nhấn mic...",
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
          // Mic button
          GestureDetector(
            onTap: _toggleRecording,
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
                            color:
                                const Color(0xFFFF1744).withValues(alpha: 0.4),
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
