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
  StreamSubscription? _bgPartialTranscriptSub;
  StreamSubscription? _bgErrorSub;
  Timer? _partialTranscriptClearTimer;
  String _liveInputText = '';
  String _liveInputLanguage = '';
  String _liveInputSpeaker = '';

  // ── Audio routing state ───────────────────────────────────────────────
  static const _audioChannel = MethodChannel(
    'com.example.machinetranslateai/audio',
  );
  String? _lastAudioTarget; // tránh gọi route liên tục cùng target

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

      // ── AUDIO ROUTING ─────────────────────────────────────────────────
      // Re-assert route on every response. Android may switch Bluetooth routes
      // between TTS turns when multiple BT devices are connected.
      final audioTarget = event['audioTarget'] as String?;
      if (audioTarget != null &&
          _config.mode == TranslateMode.proTranslate &&
          _config.proTranslationType == 'two_way') {
        _lastAudioTarget = audioTarget;
        _routeAudioForTarget(audioTarget); // re-assert route before every TTS response
      }
      // ─────────────────────────────────────────────────────────────────

      final text = event['text'] as String? ?? '';
      final speaker = event['speaker'] as String? ?? 'bot';
      final isFinal = event['isFinal'] as bool? ?? true;
      final sourceText = event['sourceText'] as String? ?? '';
      final isProTranslate = event['isProTranslate'] as bool? ?? false;
      if (text.isEmpty) return;

      setState(() {
        if (_liveInputText.isNotEmpty) {
          _partialTranscriptClearTimer?.cancel();
          _liveInputText = '';
          _liveInputLanguage = '';
          _liveInputSpeaker = '';
        }

        bool isUserSpeaking =
            speaker == 'user' ||
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
              audioTarget: audioTarget,
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
              audioTarget: audioTarget,
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
                audioTarget: audioTarget,
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

    _bgPartialTranscriptSub = _bgService.on('aiPartialTranscript').listen((
      event,
    ) {
      if (!mounted || event == null) return;
      final text = event['text'] as String? ?? '';
      if (text.trim().isEmpty) return;

      _partialTranscriptClearTimer?.cancel();
      setState(() {
        _liveInputText = text;
        _liveInputLanguage = event['language'] as String? ?? '';
        _liveInputSpeaker = event['speaker'] as String? ?? '';
      });

      _partialTranscriptClearTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() {
          _liveInputText = '';
          _liveInputLanguage = '';
          _liveInputSpeaker = '';
        });
      });
    });

    _bgErrorSub = _bgService.on('aiError').listen((event) {
      if (!mounted || event == null) return;
      final msg = event['message'] as String? ?? 'Unknown error';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: const Color(0xFFEF4444)),
      );
    });
  }

  // ── Audio routing helpers ─────────────────────────────────────────────

  /// Route audio đến device tương ứng với audioTarget
  Future<void> _routeAudioForTarget(String audioTarget) async {
    final deviceId = audioTarget == 'speaker1'
        ? _config.proSpeaker1DeviceId
        : _config.proSpeaker2DeviceId;

    if (deviceId.isEmpty) {
      debugPrint('[AudioRoute] $audioTarget: chưa config device, bỏ qua');
      return;
    }

    try {
      final ok = await _audioChannel.invokeMethod<bool>('routeAudioToDevice', {
        'deviceId': deviceId,
      });
      debugPrint('[AudioRoute] $audioTarget → $deviceId: $ok');
      if (ok != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Không route được ${audioTarget == "speaker1" ? "Loa 1" : "Loa 2"} tới thiết bị đã chọn',
            ),
            backgroundColor: const Color(0xFFEF4444),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[AudioRoute] Lỗi route $audioTarget: $e');
    }
  }

  /// Reset routing về default khi stop
  Future<void> _resetAudioRouting() async {
    try {
      await _audioChannel.invokeMethod('routeAudioToDefault');
      _lastAudioTarget = null;
      debugPrint('[AudioRoute] Reset về default');
    } catch (e) {
      debugPrint('[AudioRoute] Lỗi reset: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _bgTranscriptSub?.cancel();
    _bgPartialTranscriptSub?.cancel();
    _bgErrorSub?.cancel();
    _partialTranscriptClearTimer?.cancel();
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

    try {
      await _audioChannel.invokeMethod('setAudioOutput', {
        'type': _config.audioOutput.name,
      });
      await _audioChannel.invokeMethod('setAudioStreamType', {
        'type': _config.audioStreamType.name,
      });
      debugPrint('Audio setup: ${_config.audioOutput.name}');
    } catch (e) {
      debugPrint('Audio setup error: $e');
    }

    // Reset routing state khi bắt đầu session mới
    _lastAudioTarget = null;

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
    // Reset audio routing về default trước khi dừng
    await _resetAudioRouting();
    _partialTranscriptClearTimer?.cancel();

    await _serviceManager.stopAiTranslate();
    if (mounted) {
      setState(() {
        _liveInputText = '';
        _liveInputLanguage = '';
        _liveInputSpeaker = '';
      });
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
            child: const Text('OK', style: TextStyle(color: Color(0xFF0EA5E9))),
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
          icon: const Icon(
            Icons.arrow_back_ios_rounded,
            color: Color(0xFF0F172A),
          ),
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
          _buildLiveInputPanel(isBgRunning),
          _buildChatArea(isBgRunning),
          _buildBottomBar(isBgRunning),
        ],
      ),
    );
  }

  Widget _buildStatusBar(bool isBgRunning) {
    final color = isBgRunning
        ? const Color(0xFF0EA5E9)
        : const Color(0xFF94A3B8);
    final stateText = isBgRunning ? 'ĐANG CHẠY NGẦM' : 'Chưa chạy';

    // Hiển thị thông tin routing nếu đang active
    final isRouting =
        isBgRunning &&
        _config.mode == TranslateMode.proTranslate &&
        _config.proTranslationType == 'two_way' &&
        (_config.proSpeaker1DeviceId.isNotEmpty ||
            _config.proSpeaker2DeviceId.isNotEmpty);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: const Color(0xFFE2E8F0))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: isBgRunning
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.4),
                            blurRadius: 6,
                          ),
                        ]
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
                const Icon(Icons.mic, color: Color(0xFF0EA5E9), size: 18),
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
          // Hiển thị routing status khi đang route audio
          if (isRouting) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.bluetooth_audio_rounded,
                  size: 13,
                  color: Color(0xFF10B981),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _lastAudioTarget != null
                        ? 'Đang phát: ${_lastAudioTarget == "speaker1" ? "Loa 1" : "Loa 2"}'
                        : 'Dual BT routing bật',
                    style: const TextStyle(
                      color: Color(0xFF10B981),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveInputPanel(bool isBgRunning) {
    if (!isBgRunning || _liveInputText.isEmpty) {
      return const SizedBox.shrink();
    }

    final meta = [
      if (_liveInputSpeaker.isNotEmpty) 'Speaker $_liveInputSpeaker',
      if (_liveInputLanguage.isNotEmpty) _liveInputLanguage.toUpperCase(),
    ].join(' • ');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.graphic_eq_rounded,
              size: 18,
              color: Color(0xFF0EA5E9),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Live input',
                      style: TextStyle(
                        color: Color(0xFF0369A1),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          meta,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _liveInputText,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
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
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
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

    if (msg.isProTranslate) {
      return _buildProTranslateBubble(msg);
    }

    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
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
          border: Border.all(color: speakerColor.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
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
                const Spacer(),
                // Badge hiển thị đang phát ở loa nào
                if (msg.audioTarget != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.bluetooth_audio_rounded,
                          size: 11,
                          color: Color(0xFF10B981),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          msg.audioTarget == 'speaker1' ? 'Loa 1' : 'Loa 2',
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

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
                  'Dịch:',
                  style: TextStyle(
                    color: speakerColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],

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
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
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
  final String? audioTarget; // ← MỚI: để hiển thị badge loa

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
    this.audioTarget, // ← MỚI
  });

  String get speakerLabel {
    if (isSystem) return 'System';
    if (isLlm) return 'LLM';
    if (isProTranslate) {
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

  static const _audioChannel = MethodChannel(
    'com.example.machinetranslateai/audio',
  );
  List<AudioDevice> _audioDevices = [];
  bool _loadingDevices = true;

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
    _loadAudioDevices();
  }

  Future<void> _loadAudioDevices() async {
    if (await Permission.bluetoothConnect.isDenied) {
      await Permission.bluetoothConnect.request();
    }

    try {
      final result = await _audioChannel.invokeMethod('listAudioDevices');
      if (result is List) {
        setState(() {
          _audioDevices = result
              .map((e) => AudioDevice.fromMap(e as Map<dynamic, dynamic>))
              .toList();
          _loadingDevices = false;
        });
      }
    } catch (e) {
      debugPrint('Load audio devices error: $e');
      setState(() => _loadingDevices = false);
    }
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

  List<String> _ttsModelsForLanguage(String language) {
    return proTtsModelsByLanguage[language] ?? const [];
  }

  String _validTtsModelForLanguage(String current, String language) {
    final models = _ttsModelsForLanguage(language);
    if (models.isEmpty) return '';
    return models.contains(current) ? current : models.first;
  }

  void _normalizeProTtsModels(AiTranslateConfig c) {
    if (c.proTranslationType == 'two_way') {
      c.proTtsModel = _validTtsModelForLanguage(
        c.proTtsModel,
        c.proSourceLanguage,
      );
      c.proTtsModelB = _validTtsModelForLanguage(
        c.proTtsModelB,
        c.proTargetLanguage,
      );
    } else {
      c.proTtsModel = _validTtsModelForLanguage(
        c.proTtsModel,
        c.proTargetLanguage,
      );
    }
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
    if (isProTranslate) _normalizeProTtsModels(c);

    return Padding(
      padding: EdgeInsets.only(bottom: bottom, left: 24, right: 24, top: 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              _sectionLabel('Your language *'),
              _dropdown(
                c.proSourceLanguage,
                proLanguages,
                (v) => setState(() {
                  c.proSourceLanguage = v;
                  _normalizeProTtsModels(c);
                }),
              ),
              const SizedBox(height: 16),

              _sectionLabel("Other person's language *"),
              _dropdown(
                c.proTargetLanguage,
                proLanguages,
                (v) => setState(() {
                  c.proTargetLanguage = v;
                  _normalizeProTtsModels(c);
                }),
              ),
              const SizedBox(height: 16),

              _sectionLabel('Translation type'),
              _dropdown(
                c.proTranslationType,
                proTranslationTypes,
                (v) => setState(() {
                  c.proTranslationType = v;
                  _normalizeProTtsModels(c);
                }),
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

              if (c.proTranslationType == 'two_way') ...[
                _sectionLabel('TTS Model (Your language)'),
                _ttsModelDropdown(
                  value: c.proTtsModel,
                  language: c.proSourceLanguage,
                  onChanged: (v) => setState(() => c.proTtsModel = v),
                ),
                const SizedBox(height: 10),
                _sectionLabel("TTS Model (Other person's language)"),
                _ttsModelDropdown(
                  value: c.proTtsModelB,
                  language: c.proTargetLanguage,
                  onChanged: (v) => setState(() => c.proTtsModelB = v),
                ),
              ] else ...[
                _sectionLabel("TTS Model (Other person's language)"),
                _ttsModelDropdown(
                  value: c.proTtsModel,
                  language: c.proTargetLanguage,
                  onChanged: (v) => setState(() => c.proTtsModel = v),
                ),
              ],
              const SizedBox(height: 16),

              // Audio Device Routing (TWO_WAY)
              if (c.proTranslationType == 'two_way') ...[
                _twoWayAdvancedSection(c),
                const SizedBox(height: 16),

                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      initiallyExpanded: true,
                      title: Row(
                        children: [
                          const Icon(
                            Icons.surround_sound_rounded,
                            size: 20,
                            color: Color(0xFF0EA5E9),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Audio Device Routing',
                            style: TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Text(
                        'Chọn thiết bị cho từng loa phát',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                        ),
                      ),
                      children: [
                        if (_loadingDevices) ...[
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF0EA5E9),
                                ),
                              ),
                            ),
                          ),
                        ] else ...[
                          _sectionLabel('INPUT MIC'),
                          _audioDeviceDropdown(
                            selectedId: c.proMicDeviceId,
                            devices: _inputDevices,
                            onChanged: (v) =>
                                setState(() => c.proMicDeviceId = v),
                            hint: 'Select input mic',
                          ),
                          const SizedBox(height: 16),

                          _sectionLabel(
                            'OUTPUT 1 - SPEAKER 1',
                          ),
                          _audioDeviceDropdown(
                            selectedId: c.proSpeaker1DeviceId,
                            devices: _outputDevices,
                            onChanged: (v) =>
                                setState(() => c.proSpeaker1DeviceId = v),
                            hint: 'Select Speaker 1 output',
                          ),
                          const SizedBox(height: 16),

                          _sectionLabel(
                            'OUTPUT 2 - SPEAKER 2',
                          ),
                          _audioDeviceDropdown(
                            selectedId: c.proSpeaker2DeviceId,
                            devices: _outputDevices,
                            onChanged: (v) =>
                                setState(() => c.proSpeaker2DeviceId = v),
                            hint: 'Select Speaker 2 output',
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

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

            if (!(isProTranslate && c.proTranslationType == 'two_way')) ...[
              _sectionLabel('Loa phát âm thanh'),
              _audioOutputSelector(c),
              const SizedBox(height: 24),
            ],

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
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
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
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
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

  Widget _ttsModelDropdown({
    required String value,
    required String language,
    required ValueChanged<String> onChanged,
  }) {
    final models = _ttsModelsForLanguage(language);
    if (models.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Text(
          'No Piper TTS model for ${language.toUpperCase()}',
          style: const TextStyle(color: Color(0xFFEF4444), fontSize: 14),
        ),
      );
    }

    final effectiveValue = models.contains(value) ? value : models.first;
    return _dropdown(effectiveValue, models, onChanged);
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
        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14),
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

  Widget _twoWayAdvancedSection(AiTranslateConfig c) {
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
            'Advanced',
            style: TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text(
            'TWO_WAY routing logic',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
          ),
          children: [
            _sectionLabel('Process Logic'),
            _processLogicDropdown(
              value: c.proTwoWayProcessLogic,
              onChanged: (v) => setState(() => c.proTwoWayProcessLogic = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _processLogicDropdown({
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final effectiveValue = proTwoWayProcessLogics.contains(value)
        ? value
        : 'speaker';
    const labels = {
      'speaker': 'Process Logic Speaker (Default)',
      'translate': 'Process Logic Translate',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButton<String>(
        value: effectiveValue,
        isExpanded: true,
        dropdownColor: Colors.white,
        underline: const SizedBox(),
        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14),
        items: proTwoWayProcessLogics.map((logic) {
          return DropdownMenuItem(
            value: logic,
            child: Text(labels[logic] ?? logic),
          );
        }).toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  List<AudioDevice> get _inputDevices =>
      _audioDevices.where((d) => !d.isOutput).toList();

  List<AudioDevice> get _outputDevices =>
      _audioDevices.where((d) => d.isOutput).toList();

  Widget _audioDeviceDropdown({
    required String selectedId,
    required List<AudioDevice> devices,
    required ValueChanged<String> onChanged,
    required String hint,
  }) {
    final items = <String>[''];
    for (final d in devices) {
      if (!items.contains(d.id)) items.add(d.id);
    }
    final effectiveValue = items.contains(selectedId) ? selectedId : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButton<String>(
        value: effectiveValue,
        isExpanded: true,
        dropdownColor: Colors.white,
        underline: const SizedBox(),
        style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14),
        items: items.map((id) {
          if (id.isEmpty) {
            return DropdownMenuItem(
              value: '',
              child: Row(
                children: [
                  const Icon(
                    Icons.phone_android_rounded,
                    size: 18,
                    color: Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    hint,
                    style: const TextStyle(color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            );
          }
          final device = devices.firstWhere(
            (d) => d.id == id,
            orElse: () =>
                AudioDevice(id: id, name: 'Device $id', type: 'unknown'),
          );
          final icon = device.isBluetooth
              ? Icons.bluetooth_audio_rounded
              : device.type.contains('wired') || device.type.contains('headset')
              ? Icons.headphones_rounded
              : device.type.contains('usb')
              ? Icons.usb_rounded
              : device.type.contains('builtin_speaker')
              ? Icons.phone_android_rounded
              : device.type.contains('builtin_mic')
              ? Icons.mic_rounded
              : Icons.speaker_rounded;
          final color = device.isBluetooth
              ? const Color(0xFF0EA5E9)
              : const Color(0xFF64748B);
          return DropdownMenuItem(
            value: id,
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    device.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color),
                  ),
                ),
                if (device.isBluetooth)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'BT',
                      style: TextStyle(
                        color: Color(0xFF0EA5E9),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
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
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
        value: value,
        onChanged: onChanged,
        activeThumbColor: const Color(0xFF0EA5E9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                        controller: TextEditingController(
                          text: item['key'] ?? '',
                        ),
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                        ),
                        decoration: _compactInputDecoration('key (vd: domain)'),
                        onChanged: (v) => c.proSonioxContextGeneral[i] = {
                          'key': v,
                          'value': item['value'] ?? '',
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(
                          text: item['value'] ?? '',
                        ),
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                        ),
                        decoration: _compactInputDecoration('value'),
                        onChanged: (v) => c.proSonioxContextGeneral[i] = {
                          'key': item['key'] ?? '',
                          'value': v,
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => c.proSonioxContextGeneral.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(
                  () => c.proSonioxContextGeneral.add({'key': '', 'value': ''}),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm domain'),
              ),
            ),
            const SizedBox(height: 8),

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
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                        ),
                        decoration: _compactInputDecoration(
                          'Thuật ngữ (vd: Insulin)',
                        ),
                        onChanged: (v) => c.proSonioxContextTerms[i] = v,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => c.proSonioxContextTerms.removeAt(i)),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => c.proSonioxContextTerms.add('')),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm thuật ngữ'),
              ),
            ),
            const SizedBox(height: 8),

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
                        controller: TextEditingController(
                          text: item['source'] ?? '',
                        ),
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                        ),
                        decoration: _compactInputDecoration(
                          'Source (vd: stroke)',
                        ),
                        onChanged: (v) =>
                            c.proSonioxContextTranslationTerms[i] = {
                              'source': v,
                              'target': item['target'] ?? '',
                            },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(
                          text: item['target'] ?? '',
                        ),
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 13,
                        ),
                        decoration: _compactInputDecoration(
                          'Target (vd: đột quỵ)',
                        ),
                        onChanged: (v) =>
                            c.proSonioxContextTranslationTerms[i] = {
                              'source': item['source'] ?? '',
                              'target': v,
                            },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      onPressed: () => setState(
                        () => c.proSonioxContextTranslationTerms.removeAt(i),
                      ),
                    ),
                  ],
                ),
              );
            }),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(
                  () => c.proSonioxContextTranslationTerms.add({
                    'source': '',
                    'target': '',
                  }),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Thêm bản dịch'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _compactInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
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
    );
  }
}
