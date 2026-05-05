import 'package:flutter/material.dart';
import '../services/mt_service.dart';

class ModelDownloadDialog extends StatefulWidget {
  final List<String> languageCodes;
  final VoidCallback onComplete;

  const ModelDownloadDialog({
    super.key,
    required this.languageCodes,
    required this.onComplete,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> languageCodes,
    required VoidCallback onComplete,
  }) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ModelDownloadDialog(
        languageCodes: languageCodes,
        onComplete: onComplete,
      ),
    );
  }

  @override
  State<ModelDownloadDialog> createState() => _ModelDownloadDialogState();
}

class _ModelDownloadDialogState extends State<ModelDownloadDialog> {
  final MtService _mtService = MtService();

  String _status = 'Đang chuẩn bị...';
  double _progress = 0.0;
  bool _isComplete = false;
  bool _hasError = false;
  int _currentStep = 0;
  int _totalSteps = 0;

  static const Map<String, String> _langNames = {
    'vi': 'Tiếng Việt',
    'en': 'English',
    'de': 'Deutsch',
    'fr': 'Français',
    'ja': '日本語',
    'ko': '한국어',
    'zh': '中文',
    'es': 'Español',
  };

  @override
  void initState() {
    super.initState();
    _totalSteps = widget.languageCodes.length;
    _startDownload();
  }

  Future<void> _startDownload() async {
    setState(() {
      _status = 'Kiểm tra model...';
      _progress = 0.0;
      _hasError = false;
    });

    try {
      for (var i = 0; i < widget.languageCodes.length; i++) {
        final langCode = widget.languageCodes[i];
        final langName = _langNames[langCode] ?? langCode;

        setState(() {
          _currentStep = i + 1;
          _status = 'Đang tải model $langName...';
        });

        final isDownloaded = await _mtService.isModelDownloaded(langCode);

        if (isDownloaded) {
          setState(() {
            _status = '✓ Model $langName đã có';
            _progress = (i + 1) / _totalSteps;
          });
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        setState(() {
          _status = 'Đang tải model $langName...';
        });

        final success = await _mtService.downloadModel(langCode);

        if (!success) {
          setState(() {
            _hasError = true;
            _status = 'Lỗi tải model $langName';
          });
          return;
        }

        setState(() {
          _progress = (i + 1) / _totalSteps;
          _status = '✓ Tải xong $langName';
        });

        await Future.delayed(const Duration(milliseconds: 200));
      }

      setState(() {
        _isComplete = true;
        _status = 'Hoàn tất!';
        _progress = 1.0;
      });

      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        Navigator.of(context).pop();
        widget.onComplete();
      }
    } catch (e) {
      setState(() {
        _hasError = true;
        _status = 'Lỗi: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _hasError
                    ? Colors.red.shade900.withValues(alpha: 0.3)
                    : _isComplete
                        ? Colors.green.shade900.withValues(alpha: 0.3)
                        : const Color(0xFF2196F3).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _hasError
                    ? Icons.error_outline_rounded
                    : _isComplete
                        ? Icons.check_circle_outline_rounded
                        : Icons.cloud_download_outlined,
                color: _hasError
                    ? Colors.red.shade300
                    : _isComplete
                        ? Colors.green.shade300
                        : const Color(0xFF2196F3),
                size: 32,
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Text(
              _hasError
                  ? 'Lỗi tải dữ liệu'
                  : _isComplete
                      ? 'Tải hoàn tất!'
                      : 'Đang tải dữ liệu ngôn ngữ',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            // Status
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _hasError ? Colors.red.shade300 : Colors.grey.shade400,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),

            // Step counter
            if (!_isComplete && !_hasError)
              Text(
                '$_currentStep / $_totalSteps',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 20),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: const Color(0xFF2A2A2A),
                valueColor: AlwaysStoppedAnimation<Color>(
                  _hasError
                      ? Colors.red.shade400
                      : _isComplete
                          ? Colors.green.shade400
                          : const Color(0xFF2196F3),
                ),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),

            // Percentage
            Text(
              '${(_progress * 100).toInt()}%',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),

            if (_hasError) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _hasError = false;
                    _isComplete = false;
                    _currentStep = 0;
                    _progress = 0.0;
                  });
                  _startDownload();
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Thử lại'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2196F3),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],

            // Language list
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: widget.languageCodes.map((code) {
                final name = _langNames[code] ?? code;
                final isCurrentStep =
                    widget.languageCodes.indexOf(code) == _currentStep - 1;
                return Chip(
                  label: Text(
                    name,
                    style: TextStyle(
                      color: isCurrentStep ? Colors.white : Colors.grey.shade500,
                      fontSize: 11,
                    ),
                  ),
                  backgroundColor: isCurrentStep
                      ? const Color(0xFF2196F3).withValues(alpha: 0.3)
                      : const Color(0xFF2A2A2A),
                  side: BorderSide(
                    color: isCurrentStep
                        ? const Color(0xFF2196F3)
                        : Colors.transparent,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
