import 'package:flutter/material.dart';
import '../services/license_service.dart';

class LicenseDialog extends StatefulWidget {
  final VoidCallback onLicensed;

  const LicenseDialog({super.key, required this.onLicensed});

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => LicenseDialog(
        onLicensed: () => Navigator.of(context).pop(true),
      ),
    );
    return result ?? false;
  }

  @override
  State<LicenseDialog> createState() => _LicenseDialogState();
}

class _LicenseDialogState extends State<LicenseDialog> {
  final _controller = TextEditingController();
  String? _errorText;
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() => _errorText = 'Vui lòng nhập key');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    final result = LicenseService.validateKey(key);

    if (result.status == LicenseStatus.valid) {
      await LicenseService.saveLicense(key);
      if (mounted) widget.onLicensed();
    } else {
      setState(() {
        _errorText = result.message ?? 'Key không hợp lệ';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
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
                color: const Color(0xFF8E24AA).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                size: 32,
                color: Color(0xFF8E24AA),
              ),
            ),
            const SizedBox(height: 16),

            // Title
            const Text(
              'AI Translate bị khóa',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            // Subtitle
            Text(
              'Nhập license key để mở khóa tính năng',
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            // Input field
            TextField(
              controller: _controller,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                letterSpacing: 2,
              ),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                hintStyle: TextStyle(
                  color: Colors.grey.shade600,
                  letterSpacing: 2,
                ),
                errorText: _errorText,
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade700),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade700),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(0xFF8E24AA),
                    width: 2,
                  ),
                ),
                prefixIcon: const Icon(
                  Icons.vpn_key_rounded,
                  color: Color(0xFF8E24AA),
                ),
              ),
              onSubmitted: (_) => _activate(),
            ),
            const SizedBox(height: 24),

            // Activate button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _activate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8E24AA),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'KÍCH HOẠT',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // Cancel
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Hủy',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
