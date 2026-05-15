import 'dart:async';
import 'package:flutter/material.dart';
import '../services/stt_service.dart';
import '../services/mt_service.dart';
import '../services/tts_service.dart';
import '../services/service_manager.dart';
import '../widgets/model_download_dialog.dart';

class _ChatMessage {
  final String source;
  final String translated;
  final bool isFinal;
  _ChatMessage({required this.source, this.translated = '', this.isFinal = true});
}

class OfflineTranslateScreen extends StatefulWidget {
  const OfflineTranslateScreen({super.key});

  @override
  State<OfflineTranslateScreen> createState() => _OfflineTranslateScreenState();
}

class _OfflineTranslateScreenState extends State<OfflineTranslateScreen>
    with TickerProviderStateMixin {
  final SttService _sttService = SttService();
  final MtService _mtService = MtService();
  final TtsService _ttsService = TtsService();
  final ServiceManager _serviceManager = ServiceManager();

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<_ChatMessage> _messages = [];

  static const List<Map<String, String>> _languages = [
    {'name': 'Tiếng Việt', 'code': 'vi', 'flag': '🇻🇳'},
    {'name': 'English', 'code': 'en', 'flag': '🇬🇧'},
    {'name': 'Deutsch', 'code': 'de', 'flag': '🇩🇪'},
  ];

  String _sourceLang = "Tiếng Việt";
  String _targetLang = "English";
  bool _isRecording = false;
  String? _errorMessage;

  bool _sttReady = false;
  bool _mtReady = false;
  bool _ttsReady = false;
  bool _autoSpeak = true;
  String? _currentlySpeakingText;

  Timer? _interimDebounce;
  String _lastInterimText = '';
  DateTime _lastInterimUpdate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _setupSttCallbacks();
    _setupTtsCallbacks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDownloadDialog();
    });
  }

  void _setupTtsCallbacks() {
    _ttsService.onStart = () {
      if (mounted) setState(() {});
    };

    _ttsService.onComplete = () {
      if (mounted) {
        setState(() {
          _currentlySpeakingText = null;
        });
      }
    };

    _ttsService.onError = (error) {
      if (mounted) {
        setState(() {
          _currentlySpeakingText = null;
        });
        debugPrint('[TTS] Error: $error');
      }
    };
  }

  Future<void> _showDownloadDialog() async {
    final sourceCode = _getLangCode(_sourceLang);
    final targetCode = _getLangCode(_targetLang);
    final langCodes = <String>{sourceCode, targetCode}.toList();

    bool allDownloaded = true;
    for (final code in langCodes) {
      final isDownloaded = await _mtService.isModelDownloaded(code);
      if (!isDownloaded) {
        allDownloaded = false;
        break;
      }
    }

    if (allDownloaded) {
      debugPrint('[MT] All models already downloaded, skipping dialog');
      _initializeServices();
      return;
    }

    if (mounted) {
      ModelDownloadDialog.show(
        context,
        languageCodes: langCodes,
        onComplete: () {
          _initializeServices();
        },
      );
    }
  }

  void _setupSttCallbacks() {
    _sttService.onInterimText = (text) {
      if (!mounted) return;
      if (text == _lastInterimText) return;
      _lastInterimText = text;

      _interimDebounce?.cancel();
      _interimDebounce = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;

        final now = DateTime.now();
        if (now.difference(_lastInterimUpdate).inMilliseconds < 100) return;
        _lastInterimUpdate = now;

        setState(() {
          _errorMessage = null;
          final interimIdx = _messages.lastIndexWhere((m) => !m.isFinal);
          if (interimIdx >= 0) {
            _messages[interimIdx] = _ChatMessage(
              source: text,
              isFinal: false,
            );
          } else {
            _messages.add(_ChatMessage(source: text, isFinal: false));
          }
        });
        _scrollToBottom();
      });
    };

    _sttService.onTextRecognized = (text) async {
      if (!mounted) return;
      _interimDebounce?.cancel();
      _lastInterimText = '';

      setState(() {
        _messages.removeWhere((m) => !m.isFinal);
      });

      String translated = '';
      if (_mtReady) {
        translated = await _mtService.translate(text);
      }

      if (!mounted) return;

      setState(() {
        _errorMessage = null;
        _messages.add(_ChatMessage(
          source: text,
          translated: translated,
          isFinal: true,
        ));
      });
      _scrollToBottom();

      if (_autoSpeak && translated.isNotEmpty && _ttsReady) {
        _speakText(translated, _getLangCode(_targetLang));
      }
    };

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

    try {
      await _mtService.initialize(
        _getLangCode(_sourceLang),
        _getLangCode(_targetLang),
      );
      if (mounted) setState(() => _mtReady = _mtService.isReady);
    } catch (e) {
      debugPrint('[MT] Init failed: $e');
    }

    try {
      await _ttsService.initialize();
      if (mounted) setState(() => _ttsReady = true);
    } catch (e) {
      debugPrint('[TTS] Init failed: $e');
    }
  }

  @override
  void dispose() {
    _interimDebounce?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _sttService.dispose();
    _mtService.dispose();
    _ttsService.dispose();
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

  Future<void> _submitManualText(String text) async {
    if (text.trim().isEmpty) return;

    String translated = '';
    if (_mtReady) {
      translated = await _mtService.translate(text.trim());
    }

    if (!mounted) return;

    setState(() {
      _messages.add(_ChatMessage(
        source: text.trim(),
        translated: translated,
        isFinal: true,
      ));
    });
    _scrollToBottom();

    if (_autoSpeak && translated.isNotEmpty && _ttsReady) {
      _speakText(translated, _getLangCode(_targetLang));
    }
  }

  Future<void> _speakText(String text, String langCode) async {
    if (text.trim().isEmpty || !_ttsReady) return;

    setState(() {
      _currentlySpeakingText = text;
    });

    await _ttsService.speakWithLanguage(text, langCode);
  }

  Future<void> _stopSpeaking() async {
    await _ttsService.stop();
    setState(() {
      _currentlySpeakingText = null;
    });
  }

  Future<void> _changeSourceLang(String lang) async {
    if (_sourceLang == lang) return;

    if (_isRecording) {
      setState(() => _isRecording = false);
      await _sttService.stopStream();
    }

    setState(() {
      _sourceLang = lang;
      _sttReady = false;
      _mtReady = false;
      _errorMessage = null;
    });

    final sourceCode = _getLangCode(_sourceLang);
    final targetCode = _getLangCode(_targetLang);
    final langCodes = <String>{sourceCode, targetCode}.toList();

    bool needsDownload = false;
    for (final code in langCodes) {
      final isDownloaded = await _mtService.isModelDownloaded(code);
      if (!isDownloaded) {
        needsDownload = true;
        break;
      }
    }

    if (needsDownload && mounted) {
      ModelDownloadDialog.show(
        context,
        languageCodes: langCodes,
        onComplete: () => _reinitServices(),
      );
    } else {
      await _reinitServices();
    }
  }

  Future<void> _changeTargetLang(String lang) async {
    if (_targetLang == lang) return;

    setState(() {
      _targetLang = lang;
      _mtReady = false;
    });

    final targetCode = _getLangCode(_targetLang);
    final isDownloaded = await _mtService.isModelDownloaded(targetCode);

    if (!isDownloaded && mounted) {
      ModelDownloadDialog.show(
        context,
        languageCodes: [targetCode],
        onComplete: () => _reinitServices(),
      );
    } else {
      await _reinitServices();
    }
  }

  Future<void> _reinitServices() async {
    await _sttService.initialize(_getLangCode(_sourceLang));
    await _mtService.initialize(
      _getLangCode(_sourceLang),
      _getLangCode(_targetLang),
    );

    await _ttsService.setLanguage(_ttsService.getTtsLanguageCode(_getLangCode(_targetLang)));

    if (mounted) {
      setState(() {
        _sttReady = _sttService.isReady;
        _mtReady = _mtService.isReady;
        _ttsReady = true;
      });
    }
  }

  Future<void> _swapLanguages() async {
    if (_isRecording) {
      setState(() => _isRecording = false);
      await _sttService.stopStream();
    }

    final tempSource = _sourceLang;
    final tempTarget = _targetLang;

    setState(() {
      _sourceLang = tempTarget;
      _targetLang = tempSource;
      _sttReady = false;
      _mtReady = false;
      _errorMessage = null;
    });

    final sourceCode = _getLangCode(_sourceLang);
    final targetCode = _getLangCode(_targetLang);
    final langCodes = <String>{sourceCode, targetCode}.toList();

    bool needsDownload = false;
    for (final code in langCodes) {
      final isDownloaded = await _mtService.isModelDownloaded(code);
      if (!isDownloaded) {
        needsDownload = true;
        break;
      }
    }

    if (needsDownload && mounted) {
      ModelDownloadDialog.show(
        context,
        languageCodes: langCodes,
        onComplete: () => _reinitServices(),
      );
    } else {
      await _reinitServices();
    }
  }

  Future<void> _startBackgroundService() async {
    final success = await _serviceManager.startOfflineTranslate();
    if (!success) return;

    await _sttService.startStream();

    setState(() {
      _isRecording = true;
      _errorMessage = null;
      _lastInterimText = '';
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Micro started in background'),
          backgroundColor: const Color(0xFF0EA5E9),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopBackgroundService() async {
    setState(() => _isRecording = false);
    await _sttService.stopStream();
    await _serviceManager.stopOfflineTranslate();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Micro stopped in background'),
          backgroundColor: const Color(0xFF64748B),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Voice Translate",
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [
          _buildStatusDot("STT", _sttReady, const Color(0xFF0EA5E9)),
          _buildStatusDot("MT", _mtReady, const Color(0xFFF59E0B)),
          _buildStatusDot("TTS", _ttsReady, const Color(0xFF8B5CF6)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              setState(() => _autoSpeak = !_autoSpeak);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_autoSpeak
                      ? 'Tự động đọc bản dịch: BẬT'
                      : 'Tự động đọc bản dịch: TẮT'),
                  duration: const Duration(seconds: 1),
                  backgroundColor: const Color(0xFF0EA5E9),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: _autoSpeak
                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.08)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _autoSpeak
                      ? const Color(0xFF0EA5E9).withValues(alpha: 0.3)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Icon(
                _autoSpeak ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: _autoSpeak
                    ? const Color(0xFF0EA5E9)
                    : const Color(0xFF94A3B8),
                size: 18,
              ),
            ),
          ),
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
            color: ready ? color : const Color(0xFFCBD5E1),
            boxShadow: ready
                ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6)]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildLangDropdown(
              value: _sourceLang,
              onChanged: (val) => _changeSourceLang(val!),
            ),
          ),
          GestureDetector(
            onTap: _swapLanguages,
            child: Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.2),
                ),
              ),
              child: const Icon(
                Icons.swap_horiz_rounded,
                color: Color(0xFF0EA5E9),
                size: 20,
              ),
            ),
          ),
          Expanded(
            child: _buildLangDropdown(
              value: _targetLang,
              onChanged: (val) => _changeTargetLang(val!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLangDropdown({
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButton<String>(
        value: value,
        onChanged: onChanged,
        isExpanded: true,
        underline: const SizedBox(),
        dropdownColor: Colors.white,
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        items: _languages.map((lang) {
          return DropdownMenuItem<String>(
            value: lang['name'],
            child: Row(
              children: [
                Text(lang['flag']!, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                Text(lang['name']!),
              ],
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
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _sttReady
                    ? const Color(0xFF0EA5E9).withValues(alpha: 0.08)
                    : const Color(0xFFF1F5F9),
              ),
              child: Icon(
                _sttReady ? Icons.mic_rounded : Icons.mic_off_rounded,
                color: _sttReady
                    ? const Color(0xFF0EA5E9)
                    : const Color(0xFFCBD5E1),
                size: 36,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _sttReady
                  ? "Sẵn sàng\nNhấn mic để bắt đầu"
                  : "Đang khởi tạo...",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _sttReady
                    ? const Color(0xFF64748B)
                    : const Color(0xFFCBD5E1),
                fontSize: 15,
                height: 1.5,
              ),
            ),
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
        return msg.isFinal ? _buildFinalMessage(msg) : _buildInterimMessage(msg);
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
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.warning_rounded,
                color: Color(0xFFEF4444),
                size: 16,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  error,
                  style: const TextStyle(
                    color: Color(0xFFDC2626),
                    fontSize: 13,
                  ),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0EA5E9).withValues(alpha: 0.08),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(
              color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  msg.source,
                  style: TextStyle(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.7),
                    fontSize: 15,
                    height: 1.4,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF0EA5E9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFinalMessage(_ChatMessage msg) {
    final isSpeakingSource = _currentlySpeakingText == msg.source;
    final isSpeakingTranslated =
        _currentlySpeakingText == msg.translated && msg.translated.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Source bubble
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.08),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
                border: Border.all(
                  color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      msg.source,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      if (isSpeakingSource) {
                        _stopSpeaking();
                      } else {
                        _speakText(msg.source, _getLangCode(_sourceLang));
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: isSpeakingSource
                            ? const Color(0xFF0EA5E9).withValues(alpha: 0.15)
                            : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isSpeakingSource
                            ? Icons.stop_rounded
                            : Icons.volume_up_rounded,
                        color: isSpeakingSource
                            ? const Color(0xFF0EA5E9)
                            : const Color(0xFF94A3B8),
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Translated bubble
          if (msg.translated.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(18),
                  ),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.translate_rounded,
                      color: Color(0xFF0EA5E9),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        msg.translated,
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 15,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        if (isSpeakingTranslated) {
                          _stopSpeaking();
                        } else {
                          _speakText(
                              msg.translated, _getLangCode(_targetLang));
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isSpeakingTranslated
                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.12)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          isSpeakingTranslated
                              ? Icons.stop_rounded
                              : Icons.volume_up_rounded,
                          color: isSpeakingTranslated
                              ? const Color(0xFF8B5CF6)
                              : const Color(0xFF94A3B8),
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: const Color(0xFFE2E8F0)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: TextField(
                controller: _inputController,
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  hintText: "Nhập text hoặc nhấn mic...",
                  hintStyle: const TextStyle(color: Color(0xFFCBD5E1)),
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
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _startBackgroundService,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFF0EA5E9), Color(0xFF38BDF8)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _stopBackgroundService,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFEF4444),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.stop_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
