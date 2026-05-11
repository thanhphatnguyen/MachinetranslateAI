import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/ai_translate_config.dart';
import '../services/pipecat_service.dart';

class AiTranslateScreen extends StatefulWidget {
  const AiTranslateScreen({super.key});

  @override
  State<AiTranslateScreen> createState() => _AiTranslateScreenState();
}

class _AiTranslateScreenState extends State<AiTranslateScreen> {
  final AiTranslateConfig _config = AiTranslateConfig();
  final PipecatService _pipecatService = PipecatService();

  bool _isLoading = true;
  bool _isMicEnabled = true;

  final List<_ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription? _connectionStateSub;
  StreamSubscription? _transcriptSub;
  StreamSubscription? _botOutputSub;
  StreamSubscription? _errorSub;

  PipecatConnectionState _connectionState = PipecatConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    _initConfig();
  }

  Future<void> _initConfig() async {
    await _config.load();
    if (mounted) setState(() => _isLoading = false);
    _setupListeners();
  }

  void _setupListeners() {
    _connectionStateSub = _pipecatService.connectionState.listen((state) {
      if (mounted) {
        setState(() => _connectionState = state);
        if (state == PipecatConnectionState.connected) {
          _addMessage(_ChatMessage(
            text: 'Đã kết nối đến server',
            isSystem: true,
          ));
        } else if (state == PipecatConnectionState.disconnected) {
          _addMessage(_ChatMessage(
            text: 'Đã ngắt kết nối',
            isSystem: true,
          ));
        } else if (state == PipecatConnectionState.error) {
          _addMessage(_ChatMessage(
            text: 'Lỗi kết nối',
            isSystem: true,
            isError: true,
          ));
        }
      }
    });

    _transcriptSub = _pipecatService.transcripts.listen((transcript) {
      final isUser = transcript.speaker.startsWith('user');
      final isLlm = transcript.speaker == 'llm';
      _addMessage(_ChatMessage(
        text: transcript.text,
        isUser: isUser,
        isLlm: isLlm,
        speakerId: transcript.speaker,
        timestamp: transcript.timestamp,
      ));
    });

    _botOutputSub = _pipecatService.botOutput.listen((text) {
      _addMessage(_ChatMessage(
        text: text,
        isUser: false,
      ));
    });

    _errorSub = _pipecatService.errors.listen((error) {
      _addMessage(_ChatMessage(
        text: error,
        isSystem: true,
        isError: true,
      ));
    });
  }

  @override
  void dispose() {
    _connectionStateSub?.cancel();
    _transcriptSub?.cancel();
    _botOutputSub?.cancel();
    _errorSub?.cancel();
    _scrollController.dispose();
    _pipecatService.disconnect();
    super.dispose();
  }

  Future<void> _connect() async {
    final errors = _config.validate();
    if (errors.isNotEmpty) {
      _showErrorDialog('Thiếu thông tin', errors.join('\n'));
      return;
    }

    await Permission.microphone.request();
    if (!await Permission.microphone.isGranted) {
      _showErrorDialog(
          'Thiếu quyền', 'Cần quyền Micro để sử dụng tính năng này');
      return;
    }

    await _pipecatService.connect(_config);
  }

  Future<void> _disconnect() async {
    await _pipecatService.disconnect();
  }

  void _toggleMic() {
    setState(() => _isMicEnabled = !_isMicEnabled);
    _pipecatService.setMicEnabled(_isMicEnabled);
  }

  void _addMessage(_ChatMessage msg) {
    if (!mounted) return;
    setState(() => _messages.add(msg));
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

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(content, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('OK', style: TextStyle(color: Color(0xFF8E24AA))),
          ),
        ],
      ),
    );
  }

  void _showSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _SettingsSheet(
        config: _config,
        onSaved: () => setState(() {}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0A0A),
        body: Center(
            child: CircularProgressIndicator(color: Color(0xFF8E24AA))),
      );
    }

    final isConnected =
        _connectionState == PipecatConnectionState.connected;
    final isConnecting =
        _connectionState == PipecatConnectionState.connecting;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text(
          'AI Translate',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _disconnect();
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white, size: 28),
            onPressed: _showSettingsModal,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(isConnected, isConnecting),
          _buildChatArea(isConnected),
          _buildBottomBar(isConnected, isConnecting),
        ],
      ),
    );
  }

  Widget _buildStatusBar(bool isConnected, bool isConnecting) {
    final color = isConnected
        ? const Color(0xFF00C853)
        : isConnecting
            ? const Color(0xFFFFAB00)
            : Colors.grey;

    final stateText = isConnected
        ? 'Connected'
        : isConnecting
            ? 'Connecting...'
            : 'Disconnected';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        border: Border(
          bottom: BorderSide(color: color.withValues(alpha: 0.3)),
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
              boxShadow: [
                BoxShadow(
                    color: color.withValues(alpha: 0.5), blurRadius: 6)
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            stateText,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (isConnected) ...[
            Icon(Icons.mic,
                color: Colors.greenAccent.shade400, size: 18),
            const SizedBox(width: 4),
            Text('Đang nghe',
                style: TextStyle(
                    color: Colors.greenAccent.shade400, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _buildChatArea(bool isConnected) {
    if (_messages.isEmpty) {
      return Expanded(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome_rounded,
                  color: Colors.white.withValues(alpha: 0.15), size: 64),
              const SizedBox(height: 16),
              Text(
                isConnected ? 'Đang lắng nghe...' : 'Nhấn kết nối để bắt đầu',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4), fontSize: 15),
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
        itemBuilder: (context, index) =>
            _buildMessageBubble(_messages[index]),
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg) {
    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: msg.isError
                  ? Colors.red.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              msg.text,
              style: TextStyle(
                color: msg.isError
                    ? Colors.red.shade300
                    : Colors.grey.shade500,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
    }

    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) _buildAvatar(false),
          if (!isUser) const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF8E24AA).withValues(alpha: 0.25)
                    : msg.isLlm
                        ? const Color(0xFF1B5E20).withValues(alpha: 0.3)
                        : const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: Border.all(
                  color: isUser
                      ? const Color(0xFF8E24AA).withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isUser
                              ? const Color(0xFF8E24AA)
                                  .withValues(alpha: 0.3)
                              : msg.isLlm
                                  ? Colors.greenAccent
                                      .withValues(alpha: 0.2)
                                  : const Color(0xFF00C853)
                                      .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          msg.speakerLabel,
                          style: TextStyle(
                            color: isUser
                                ? const Color(0xFFCE93D8)
                                : msg.isLlm
                                    ? Colors.greenAccent.shade400
                                    : const Color(0xFF69F0AE),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (msg.timestamp != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          msg.timestamp!,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    msg.text,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
          if (isUser) _buildAvatar(true),
        ],
      ),
    );
  }

  Widget _buildAvatar(bool isUser) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isUser
            ? const Color(0xFF8E24AA).withValues(alpha: 0.3)
            : const Color(0xFF00C853).withValues(alpha: 0.3),
      ),
      child: Icon(
        isUser ? Icons.person : Icons.smart_toy,
        color: isUser
            ? const Color(0xFFCE93D8)
            : const Color(0xFF69F0AE),
        size: 18,
      ),
    );
  }

  Widget _buildBottomBar(bool isConnected, bool isConnecting) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        border: Border(top: BorderSide(color: Color(0xFF222222))),
      ),
      child: Row(
        children: [
          _buildCircleButton(
            icon: _isMicEnabled ? Icons.mic : Icons.mic_off,
            color: _isMicEnabled
                ? const Color(0xFF00C853)
                : Colors.grey,
            onTap: isConnected ? _toggleMic : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: SizedBox(
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected
                      ? Colors.red
                      : isConnecting
                          ? Colors.orange
                          : const Color(0xFF8E24AA),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  elevation: 0,
                ),
                onPressed: isConnecting
                    ? null
                    : isConnected
                        ? _disconnect
                        : _connect,
                child: Text(
                  isConnecting
                      ? 'Đang kết nối...'
                      : isConnected
                          ? 'NGẮT KẾT NỐI'
                          : 'KẾT NỐI',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          _buildCircleButton(
            icon: Icons.delete_outline,
            color: Colors.grey,
            onTap: _messages.isEmpty
                ? null
                : () => setState(() => _messages.clear()),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onTap != null
              ? color.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
        ),
        child: Icon(
          icon,
          color: onTap != null
              ? color
              : Colors.grey.withValues(alpha: 0.4),
          size: 24,
        ),
      ),
    );
  }
}

class _ChatMessage {
  final String text;
  final bool isUser;
  final bool isSystem;
  final bool isError;
  final bool isLlm;
  final String? speakerId;
  final String? timestamp;

  _ChatMessage({
    required this.text,
    this.isUser = false,
    this.isSystem = false,
    this.isError = false,
    this.isLlm = false,
    this.speakerId,
    this.timestamp,
  });

  String get speakerLabel {
    if (isSystem) return 'System';
    if (isLlm) return 'LLM';
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
    await c.save();
    widget.onSaved();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã lưu cài đặt'),
          backgroundColor: Color(0xFF8E24AA),
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

    return Padding(
      padding:
          EdgeInsets.only(bottom: bottom, left: 20, right: 20, top: 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Cấu hình AI Translate',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Server URL ──
            _sectionLabel('Server URL *'),
            _textField(_serverCtrl, 'https://your-server.com'),
            const SizedBox(height: 20),

            // ── Mode Selection ──
            _sectionLabel('Chế độ'),
            _modeSelector(c),
            const SizedBox(height: 20),

            if (isGeminiLive) ...[
              // ── Gemini Live Config ──
              _sectionLabel('Google API Key *'),
              _textField(_googleKeyCtrl, 'Nhập Google API Key', obscure: true),
              const SizedBox(height: 12),

              _sectionLabel('Model'),
              _dropdown(c.geminiModel, geminiModels,
                  (v) => setState(() => c.geminiModel = v)),
              const SizedBox(height: 12),

              _sectionLabel('Voice'),
              _dropdown(c.geminiVoice, geminiVoices,
                  (v) => setState(() => c.geminiVoice = v)),
              const SizedBox(height: 12),

              _sectionLabel('Prompt (System Instruction)'),
              _textField(_geminiPromptCtrl,
                  'Nhập prompt hướng dẫn AI...',
                  maxLines: 4),
              const SizedBox(height: 20),
            ] else ...[
              // ── STT + LLM + TTS Config ──
              _sectionLabel('Speech-to-Text (STT)'),
              _dropdown(c.sttProvider, sttProviders,
                  (v) => setState(() => c.sttProvider = v)),
              if (c.sttProvider != 'none') ...[
                const SizedBox(height: 8),
                _textField(_sttKeyCtrl, 'API Key cho ${c.sttProvider}',
                    obscure: true),
              ],
              const SizedBox(height: 20),

              _sectionLabel('Language Model (LLM)'),
              _dropdown(c.llmProvider, llmProviders,
                  (v) => setState(() => c.llmProvider = v)),
              if (c.llmProvider != 'none') ...[
                const SizedBox(height: 8),
                _textField(_llmKeyCtrl, 'API Key cho ${c.llmProvider}',
                    obscure: true),
                const SizedBox(height: 8),
                _textField(_llmModelCtrl,
                    'Model ID (ví dụ: gpt-4o, claude-3-5-sonnet)'),
              ],
              const SizedBox(height: 20),

              _sectionLabel('Text-to-Speech (TTS)'),
              _dropdown(c.ttsProvider, ttsProviders,
                  (v) => setState(() => c.ttsProvider = v)),
              if (c.ttsProvider != 'none') ...[
                const SizedBox(height: 8),
                _textField(_ttsKeyCtrl, 'API Key cho ${c.ttsProvider}',
                    obscure: true),
              ],
              const SizedBox(height: 20),

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
              const SizedBox(height: 20),
            ],

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8E24AA),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: _save,
              child: const Text(
                'LƯU CÀI ĐẶT',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1,
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
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: [
          _modeOption(
            c,
            TranslateMode.sttLlmTts,
            Icons.settings_voice,
            'STT + LLM + TTS',
            '3 dịch vụ riêng biệt, linh hoạt chọn provider',
          ),
          const Divider(height: 1, color: Color(0xFF333333)),
          _modeOption(
            c,
            TranslateMode.geminiLive,
            Icons.flash_on,
            'Gemini Live',
            'Google Gemini xử lý audio trực tiếp, nhanh hơn',
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
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF8E24AA) : Colors.grey,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey,
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.grey.shade600,
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
              activeColor: const Color(0xFF8E24AA),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.grey,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController ctrl,
    String hint, {
    bool obscure = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      obscureText: obscure,
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF555555)),
        filled: true,
        fillColor: const Color(0xFF222222),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF333333)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF333333)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF8E24AA)),
        ),
      ),
    );
  }

  Widget _dropdown(
      String value, List<String> items, ValueChanged<String> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        dropdownColor: const Color(0xFF2A2A2A),
        underline: const SizedBox(),
        style: const TextStyle(color: Colors.white, fontSize: 14),
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
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        subtitle: Text(subtitle,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: const Color(0xFF8E24AA),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      ),
    );
  }
}
