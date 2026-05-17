import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/ai_translate_config.dart';
import '../services/service_manager.dart';
import 'package:flutter/services.dart';

class AiTranslateScreen extends StatefulWidget {
  const AiTranslateScreen({super.key});

  @override
  State<AiTranslateScreen> createState() => _AiTranslateScreenState();
}

class _AiTranslateScreenState extends State<AiTranslateScreen> {
  final AiTranslateConfig _config = AiTranslateConfig();
  final ServiceManager _serviceManager = ServiceManager();
  final FlutterBackgroundService _bgService = FlutterBackgroundService();
  bool _isLoading = true;

  final List<_ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription? _bgTranscriptSub;
  StreamSubscription? _bgErrorSub;

  @override
  void initState() {
    super.initState();
    _initConfig();
  }

  Future<void> _initConfig() async {
    await _config.load();
    if (mounted) setState(() => _isLoading = false);
    _setupListeners();

    _serviceManager.onStateChanged = (_) {
      if (mounted) setState(() {});
    };
  }

  void _setupListeners() {
    _bgTranscriptSub = _bgService.on('aiTranscript').listen((event) {
      if (!mounted || event == null) return;
      final text = event['text'] as String? ?? '';
      final speaker = event['speaker'] as String? ?? 'bot';
      final isFinal = event['isFinal'] as bool? ?? true;
      final sourceText = event['sourceText'] as String? ?? '';
      final isProTranslate = event['isProTranslate'] as bool? ?? false;
      if (text.isEmpty) return;

      setState(() {
        // Pro Translate: "user" hoặc speaker ID từ Soniox diarization (VD: "1", "2") = user
        // Còn lại = bot (translation)
        bool isUserSpeaking = speaker == 'user' ||
            (speaker != 'bot' && int.tryParse(speaker) != null);

        if (_messages.isEmpty) {
          _messages.add(
            _ChatMessage(
              text: text,
              isUser: isUserSpeaking,
              isFinal: isFinal,
              sourceText: sourceText,
              isProTranslate: isProTranslate,
              speakerId: speaker,
            ),
          );
        } else {
          final last = _messages.last;
          if (last.isUser == isUserSpeaking && last.isFinal == false) {
            _messages[_messages.length - 1] = _ChatMessage(
              text: text,
              isUser: isUserSpeaking,
              isFinal: isFinal,
              sourceText: sourceText,
              isProTranslate: isProTranslate,
              speakerId: speaker,
            );
          } else {
            _messages.add(
              _ChatMessage(
                text: text,
                isUser: isUserSpeaking,
                isFinal: isFinal,
                sourceText: sourceText,
                isProTranslate: isProTranslate,
                speakerId: speaker,
              ),
            );
          }
        }

        Future.delayed(const Duration(milliseconds: 50), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      });
    });

    _bgErrorSub = _bgService.on('aiError').listen((event) {
      if (!mounted || event == null) return;
      final msg = event['message'] as String? ?? 'Unknown error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    });
  }

  @override
  void dispose() {
    _bgTranscriptSub?.cancel();
    _bgErrorSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startBackground() async {
    final errors = _config.validate();
    if (errors.isNotEmpty) {
      _showErrorDialog('Thiếu thông tin', errors.join('\n'));
      return;
    }

    await Permission.notification.request();
    await Permission.microphone.request();

    if (!await Permission.microphone.isGranted) {
      _showErrorDialog(
        'Thiếu quyền',
        'Cần quyền Micro để sử dụng tính năng này',
      );
      return;
    }

    const audioChannel = MethodChannel('com.example.machinetranslateai/audio');
    try {
      await audioChannel.invokeMethod('setAudioOutput', {
        'type': _config.audioOutput.name,
      });
      await audioChannel.invokeMethod('setAudioStreamType', {
        'type': _config.audioStreamType.name,
      });
      debugPrint('Audio setup: ${_config.audioOutput.name}');
    } catch (e) {
      debugPrint('Audio setup error: $e');
    }
    await _config.save();
    final success = await _serviceManager.startAiTranslate();
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã bắt đầu chạy ngầm!'),
          backgroundColor: Color(0xFF0EA5E9),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopBackground() async {
    await _serviceManager.stopAiTranslate();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã dừng chạy ngầm'),
          backgroundColor: Color(0xFF64748B),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          title,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          content,
          style: const TextStyle(color: Color(0xFF64748B)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'OK',
              style: TextStyle(color: Color(0xFF0EA5E9)),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          _SettingsSheet(config: _config, onSaved: () => setState(() {})),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF0EA5E9)),
        ),
      );
    }

    final isBgRunning = _serviceManager.isAiTranslateRunning;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'AI Translate',
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings_rounded,
              color: Color(0xFF64748B),
              size: 24,
            ),
            onPressed: _showSettingsModal,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(isBgRunning),
          _buildChatArea(isBgRunning),
          _buildBottomBar(isBgRunning),
        ],
      ),
    );
  }

  Widget _buildStatusBar(bool isBgRunning) {
    final color = isBgRunning ? const Color(0xFF0EA5E9) : const Color(0xFF94A3B8);
    final stateText = isBgRunning ? 'ĐANG CHẠY NGẦM' : 'Chưa chạy';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: const Color(0xFFE2E8F0)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: isBgRunning
                  ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            stateText,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (isBgRunning) ...[
            const Icon(
              Icons.mic,
              color: Color(0xFF0EA5E9),
              size: 18,
            ),
            const SizedBox(width: 6),
            const Text(
              'Đang nghe',
              style: TextStyle(
                color: Color(0xFF0EA5E9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatArea(bool isBgRunning) {
    if (_messages.isEmpty) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.06),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.4),
                  size: 36,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isBgRunning ? 'Đang lắng nghe...' : 'Nhấn chạy ngầm để bắt đầu',
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Expanded(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _messages.length,
        itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg) {
    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: msg.isError
                  ? const Color(0xFFFEF2F2)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: msg.isError
                    ? const Color(0xFFFECACA)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Text(
              msg.text,
              style: TextStyle(
                color: msg.isError
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF64748B),
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
    }

    // Pro Translate display
    if (msg.isProTranslate) {
      return _buildProTranslateBubble(msg);
    }

    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) _buildAvatar(false),
          if (!isUser) const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.08)
                    : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 18),
                ),
                border: Border.all(
                  color: isUser
                      ? const Color(0xFF0EA5E9).withValues(alpha: 0.15)
                      : const Color(0xFFE2E8F0),
                ),
                boxShadow: isUser
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: isUser
                              ? const Color(0xFF0EA5E9).withValues(alpha: 0.1)
                              : msg.isLlm
                              ? const Color(0xFF10B981).withValues(alpha: 0.1)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          msg.speakerLabel,
                          style: TextStyle(
                            color: isUser
                                ? const Color(0xFF0EA5E9)
                                : msg.isLlm
                                ? const Color(0xFF10B981)
                                : const Color(0xFF64748B),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (msg.timestamp != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          msg.timestamp!,
                          style: const TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    msg.text,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 10),
          if (isUser) _buildAvatar(true),
        ],
      ),
    );
  }

  Widget _buildAvatar(bool isUser) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isUser
            ? const Color(0xFF0EA5E9).withValues(alpha: 0.1)
            : const Color(0xFF10B981).withValues(alpha: 0.1),
      ),
      child: Icon(
        isUser ? Icons.person_rounded : Icons.smart_toy_rounded,
        color: isUser ? const Color(0xFF0EA5E9) : const Color(0xFF10B981),
        size: 18,
      ),
    );
  }

  Widget _buildProTranslateBubble(_ChatMessage msg) {
    final speakerColor = msg.isUser
        ? const Color(0xFF0EA5E9)
        : const Color(0xFF10B981);
    final bgColor = msg.isUser
        ? const Color(0xFF0EA5E9).withValues(alpha: 0.04)
        : const Color(0xFF10B981).withValues(alpha: 0.04);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: speakerColor.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Speaker label
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: speakerColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                msg.speakerLabel,
                style: TextStyle(
                  color: speakerColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Source text
            if (msg.sourceText.isNotEmpty) ...[
              Text(
                msg.sourceText,
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: speakerColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Dich:',
                  style: TextStyle(
                    color: speakerColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],

            // Translation text
            Text(
              msg.text,
              style: TextStyle(
                color: speakerColor.withValues(alpha: 0.9),
                fontSize: 15,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(bool isBgRunning) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: const Color(0xFFE2E8F0))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _messages.isEmpty
                    ? null
                    : () => setState(() => _messages.clear()),
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _messages.isEmpty
                        ? const Color(0xFFF1F5F9)
                        : const Color(0xFFFEF2F2),
                    border: Border.all(
                      color: _messages.isEmpty
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFFFECACA),
                    ),
                  ),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: _messages.isEmpty
                        ? const Color(0xFFCBD5E1)
                        : const Color(0xFFEF4444),
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isBgRunning
                          ? const Color(0xFFEF4444)
                          : const Color(0xFF0EA5E9),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27),
                      ),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                    ),
                    onPressed: isBgRunning ? _stopBackground : _startBackground,
                    icon: Icon(
                      isBgRunning
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                      size: 22,
                    ),
                    label: Text(
                      isBgRunning ? 'DỪNG CHẠY NGẦM' : 'CHẠY NGẦM',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (isBgRunning) ...[
            const SizedBox(height: 10),
            const Text(
              'Tắt màn hình app vẫn sẽ nghe và dịch',
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;
  final bool isFinal;
  final bool isSystem;
  final bool isError;
  final bool isLlm;
  final String? speakerId;
  final String? timestamp;
  final String sourceText;
  final bool isProTranslate;

  _ChatMessage({
    required this.text,
    this.isUser = false,
    this.isSystem = false,
    this.isError = false,
    this.isLlm = false,
    this.speakerId,
    this.timestamp,
    this.isFinal = true,
    this.sourceText = '',
    this.isProTranslate = false,
  });

  String get speakerLabel {
    if (isSystem) return 'System';
    if (isLlm) return 'LLM';
    if (isProTranslate) {
      // Hiển thị speaker thật từ Soniox diarization
      if (speakerId != null && speakerId!.isNotEmpty) {
        return 'Speaker $speakerId';
      }
      return isUser ? 'Speaker 1' : 'Speaker 2';
    }
    if (speakerId != null && speakerId!.isNotEmpty) {
      return isUser ? 'User ($speakerId)' : 'Bot ($speakerId)';
    }
    return isUser ? 'User' : 'Bot';
  }
}

// ─── Settings Sheet ──────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  final AiTranslateConfig config;
  final VoidCallback onSaved;

  const _SettingsSheet({required this.config, required this.onSaved});

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _sttKeyCtrl;
  late final TextEditingController _llmKeyCtrl;
  late final TextEditingController _llmModelCtrl;
  late final TextEditingController _ttsKeyCtrl;
  late final TextEditingController _googleKeyCtrl;
  late final TextEditingController _geminiPromptCtrl;
  late final TextEditingController _customModelCtrl;
  late final TextEditingController _proSttKeyCtrl;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _serverCtrl = TextEditingController(text: c.serverUrl);
    _sttKeyCtrl = TextEditingController(text: c.sttApiKey);
    _llmKeyCtrl = TextEditingController(text: c.llmApiKey);
    _llmModelCtrl = TextEditingController(text: c.llmModel);
    _ttsKeyCtrl = TextEditingController(text: c.ttsApiKey);
    _googleKeyCtrl = TextEditingController(text: c.googleApiKey);
    _geminiPromptCtrl = TextEditingController(text: c.geminiPrompt);
    _customModelCtrl = TextEditingController(text: c.customGeminiModel);
    _proSttKeyCtrl = TextEditingController(text: c.proSttApiKey);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _sttKeyCtrl.dispose();
    _llmKeyCtrl.dispose();
    _llmModelCtrl.dispose();
    _ttsKeyCtrl.dispose();
    _googleKeyCtrl.dispose();
    _geminiPromptCtrl.dispose();
    _customModelCtrl.dispose();
    _proSttKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.config;
    c.serverUrl = _serverCtrl.text.trim();
    c.sttApiKey = _sttKeyCtrl.text.trim();
    c.llmApiKey = _llmKeyCtrl.text.trim();
    c.llmModel = _llmModelCtrl.text.trim();
    c.ttsApiKey = _ttsKeyCtrl.text.trim();
    c.googleApiKey = _googleKeyCtrl.text.trim();
    c.geminiPrompt = _geminiPromptCtrl.text.trim();
    c.proSttApiKey = _proSttKeyCtrl.text.trim();
    await c.save();
    widget.onSaved();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã lưu cài đặt'),
          backgroundColor: Color(0xFF0EA5E9),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final isGeminiLive = c.mode == TranslateMode.geminiLive;
    final isProTranslate = c.mode == TranslateMode.proTranslate;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom, left: 24, right: 24, top: 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Cấu hình AI Translate',
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Color(0xFF94A3B8),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Server URL
            _sectionLabel('Server URL *'),
            _textField(_serverCtrl, 'https://your-server.com'),
            const SizedBox(height: 24),

            // Mode Selection
            _sectionLabel('Chế độ'),
            _modeSelector(c),
            const SizedBox(height: 24),

            if (isGeminiLive) ...[
              _sectionLabel('Google API Key *'),
              _textField(_googleKeyCtrl, 'Nhập Google API Key', obscure: true),
              const SizedBox(height: 16),

              _sectionLabel('Model'),
              _dropdown(
                c.geminiModel,
                geminiModels,
                (v) => setState(() {
                  c.geminiModel = v;
                  if (v != 'custom') c.customGeminiModel = '';
                }),
              ),
              if (c.geminiModel == 'custom') ...[
                const SizedBox(height: 10),
                _textField(
                  _customModelCtrl,
                  'Nhập tên model (vd: gemini-3.1-flash-live-preview)',
                  onChanged: (v) => c.customGeminiModel = v,
                ),
              ],
              const SizedBox(height: 16),

              _sectionLabel('Voice'),
              _dropdown(
                c.geminiVoice,
                geminiVoices,
                (v) => setState(() => c.geminiVoice = v),
              ),
              const SizedBox(height: 16),

              _sectionLabel('Prompt (System Instruction)'),
              _textField(
                _geminiPromptCtrl,
                'Nhập prompt hướng dẫn AI...',
                maxLines: 4,
              ),
              const SizedBox(height: 24),
            ] else if (isProTranslate) ...[
              _sectionLabel('Ngôn ngữ nguồn *'),
              _dropdown(
                c.proSourceLanguage,
                proLanguages,
                (v) => setState(() => c.proSourceLanguage = v),
              ),
              const SizedBox(height: 16),

              _sectionLabel('Ngôn ngữ đích *'),
              _dropdown(
                c.proTargetLanguage,
                proLanguages,
                (v) => setState(() => c.proTargetLanguage = v),
              ),
              const SizedBox(height: 16),

              _sectionLabel('Loại dịch'),
              _dropdown(
                c.proTranslationType,
                proTranslationTypes,
                (v) => setState(() => c.proTranslationType = v),
              ),
              const SizedBox(height: 16),

              _sectionLabel('Soniox API Key *'),
              _textField(_proSttKeyCtrl, 'Nhập Soniox API Key', obscure: true),
              const SizedBox(height: 16),

              _switchTile(
                'Phân biệt giọng nói (Diarization)',
                'Nhận diện người nói khác nhau',
                c.proSttDiarize,
                (v) => setState(() => c.proSttDiarize = v),
              ),
              const SizedBox(height: 16),

              _sectionLabel('TTS Model'),
              _dropdown(
                c.proTtsModel,
                proTtsModels,
                (v) => setState(() => c.proTtsModel = v),
              ),
              if (c.proTranslationType == 'two_way') ...[
                const SizedBox(height: 10),
                _sectionLabel('TTS Model (ngôn ngữ thứ 2)'),
                _dropdown(
                  c.proTtsModelB,
                  proTtsModels,
                  (v) => setState(() => c.proTtsModelB = v),
                ),
              ],
              const SizedBox(height: 16),

              // Soniox Context (collapsible)
              _sonioxContextSection(c),
              const SizedBox(height: 24),
            ] else ...[
              _sectionLabel('Speech-to-Text (STT)'),
              _dropdown(
                c.sttProvider,
                sttProviders,
                (v) => setState(() => c.sttProvider = v),
              ),
              if (c.sttProvider != 'none') ...[
                const SizedBox(height: 10),
                _textField(
                  _sttKeyCtrl,
                  'API Key cho ${c.sttProvider}',
                  obscure: true,
                ),
              ],
              const SizedBox(height: 24),

              _sectionLabel('Language Model (LLM)'),
              _dropdown(
                c.llmProvider,
                llmProviders,
                (v) => setState(() => c.llmProvider = v),
              ),
              if (c.llmProvider != 'none') ...[
                const SizedBox(height: 10),
                _textField(
                  _llmKeyCtrl,
                  'API Key cho ${c.llmProvider}',
                  obscure: true,
                ),
                const SizedBox(height: 10),
                _textField(
                  _llmModelCtrl,
                  'Model ID (ví dụ: gpt-4o, claude-3-5-sonnet)',
                ),
              ],
              const SizedBox(height: 24),

              _sectionLabel('Text-to-Speech (TTS)'),
              _dropdown(
                c.ttsProvider,
                ttsProviders,
                (v) => setState(() => c.ttsProvider = v),
              ),
              if (c.ttsProvider != 'none') ...[
                const SizedBox(height: 10),
                _textField(
                  _ttsKeyCtrl,
                  'API Key cho ${c.ttsProvider}',
                  obscure: true,
                ),
              ],
              const SizedBox(height: 24),

              _sectionLabel('Tùy chọn'),
              _switchTile(
                'Phân biệt giọng nói',
                'Nhận diện người nói khác nhau',
                c.speakerDiarization,
                (v) => setState(() => c.speakerDiarization = v),
              ),
              _switchTile(
                'Phản hồi ngay (không đợi dịch)',
                'Hiển thị LLM output ngay khi có, không chờ TTS',
                c.instantResponse,
                (v) => setState(() => c.instantResponse = v),
              ),
              const SizedBox(height: 24),
            ],

            // Audio Output
            _sectionLabel('Loa phát âm thanh'),
            _audioOutputSelector(c),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0EA5E9),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                onPressed: _save,
                child: const Text(
                  'LƯU CÀI ĐẶT',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _modeSelector(AiTranslateConfig c) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          _modeOption(
            c,
            TranslateMode.sttLlmTts,
            Icons.settings_voice_rounded,
            'STT + LLM + TTS',
            '3 dịch vụ riêng biệt, linh hoạt chọn provider',
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          _modeOption(
            c,
            TranslateMode.geminiLive,
            Icons.flash_on_rounded,
            'Gemini Live',
            'Google Gemini xử lý audio trực tiếp, nhanh hơn',
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          _modeOption(
            c,
            TranslateMode.proTranslate,
            Icons.auto_awesome_rounded,
            'Pro Translate',
            'Soniox STT + Piper TTS, dịch chuyên nghiệp',
          ),
        ],
      ),
    );
  }

  Widget _modeOption(
    AiTranslateConfig c,
    TranslateMode mode,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final isSelected = c.mode == mode;
    return InkWell(
      onTap: () => setState(() => c.mode = mode),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isSelected
                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.1)
                    : const Color(0xFFF1F5F9),
              ),
              child: Icon(
                icon,
                color: isSelected
                    ? const Color(0xFF0EA5E9)
                    : const Color(0xFF94A3B8),
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected
                          ? const Color(0xFF0F172A)
                          : const Color(0xFF64748B),
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Radio<TranslateMode>(
              value: mode,
              groupValue: c.mode,
              onChanged: (v) => setState(() => c.mode = v!),
              activeColor: const Color(0xFF0EA5E9),
            ),
          ],
        ),
      ),
    );
  }

  Widget _audioOutputSelector(AiTranslateConfig c) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          _audioOutputOption(
            c,
            AudioOutputOption.phone,
            Icons.phone_android_rounded,
            'Mic and Speaker on Phone',
            'Mic và Loa trên điện thoại',
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          _audioOutputOption(
            c,
            AudioOutputOption.bluetooth,
            Icons.bluetooth_audio_rounded,
            'Mic and Speaker on Bluetooth Device',
            'Mic và Loa trên thiết bị Bluetooth',
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          _audioOutputOption(
            c,
            AudioOutputOption.earpiece,
            Icons.phone_in_talk_rounded,
            'Mic on Phone and Speaker on Bluetooth Device',
            'BT thì mic điện thoại và loa BT, Phone thì mic và loa điện thoại call mode',
          ),
        ],
      ),
    );
  }

  Widget _audioOutputOption(
    AiTranslateConfig c,
    AudioOutputOption option,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final isSelected = c.audioOutput == option;
    return InkWell(
      onTap: () => setState(() => c.audioOutput = option),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isSelected
                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.1)
                    : const Color(0xFFF1F5F9),
              ),
              child: Icon(
                icon,
                color: isSelected
                    ? const Color(0xFF0EA5E9)
                    : const Color(0xFF94A3B8),
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected
                          ? const Color(0xFF0F172A)
                          : const Color(0xFF64748B),
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Radio<AudioOutputOption>(
              value: option,
              groupValue: c.audioOutput,
              onChanged: (v) => setState(() => c.audioOutput = v!),
              activeColor: const Color(0xFF0EA5E9),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController ctrl,
    String hint, {
    bool obscure = false,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14),
      obscureText: obscure,
      maxLines: maxLines,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF0EA5E9), width: 1.5),
        ),
      ),
    );
  }

  Widget _dropdown(
    String value,
    List<String> items,
    ValueChanged<String> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        dropdownColor: Colors.white,
        underline: const SizedBox(),
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 14,
        ),
        items: items.map((e) {
          return DropdownMenuItem(
            value: e,
            child: Text(e == 'none' ? 'Không sử dụng' : e.toUpperCase()),
          );
        }).toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _switchTile(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 12,
          ),
        ),
        value: value,
        onChanged: onChanged,
        activeThumbColor: const Color(0xFF0EA5E9),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 4,
        ),
      ),
    );
  }

  Widget _sonioxContextSection(AiTranslateConfig c) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: const Text(
            'Soniox Context (Từ vựng chuyên ngành)',
            style: TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text(
            'Bổ sung thuật ngữ để tăng độ chính xác',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
          ),
          children: [
            // General context (domain, topic)
            _sectionLabel('Domain / Topic'),
            ...c.proSonioxContextGeneral.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: item['key'] ?? ''),
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'key (vd: domain)',
                          hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        onChanged: (v) => c.proSonioxContextGeneral[i] = {'key': v, 'value': item['value'] ?? ''},
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: item['value'] ?? ''),
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'value',
                          hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        onChanged: (v) => c.proSonioxContextGeneral[i] = {'key': item['key'] ?? '', 'value': v},
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFEF4444), size: 20),
                      onPressed: () => setState(() => c.proSonioxContextGeneral.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  c.proSonioxContextGeneral.add({'key': '', 'value': ''});
                }),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm domain'),
              ),
            ),
            const SizedBox(height: 8),

            // Terms
            _sectionLabel('Thuật ngữ chuyên ngành'),
            ...c.proSonioxContextTerms.asMap().entries.map((entry) {
              final i = entry.key;
              final term = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: term),
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Thuật ngữ (vd: Insulin)',
                          hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        onChanged: (v) => c.proSonioxContextTerms[i] = v,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFEF4444), size: 20),
                      onPressed: () => setState(() => c.proSonioxContextTerms.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  c.proSonioxContextTerms.add('');
                }),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm thuật ngữ'),
              ),
            ),
            const SizedBox(height: 8),

            // Translation terms
            _sectionLabel('Bản dịch thuật ngữ'),
            ...c.proSonioxContextTranslationTerms.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: item['source'] ?? ''),
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Source (vd: stroke)',
                          hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        onChanged: (v) => c.proSonioxContextTranslationTerms[i] = {'source': v, 'target': item['target'] ?? ''},
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: item['target'] ?? ''),
                        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Target (vd: đột quỵ)',
                          hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        onChanged: (v) => c.proSonioxContextTranslationTerms[i] = {'source': item['source'] ?? '', 'target': v},
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFEF4444), size: 20),
                      onPressed: () => setState(() => c.proSonioxContextTranslationTerms.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  c.proSonioxContextTranslationTerms.add({'source': '', 'target': ''});
                }),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm bản dịch'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
