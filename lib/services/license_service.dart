import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LicenseStatus { valid, invalid, expired, notActivated }

class LicenseResult {
  final LicenseStatus status;
  final String? message;

  LicenseResult(this.status, [this.message]);
}

class LicenseService {
  static const _storageKey = 'ai_translate_license_key';
  static const _activatedAtKey = 'ai_translate_license_activated_at';

  // Prefix bí mật để hash - chỉ bạn biết
  static const _secretPrefix = 'MTAI-2026';

  // Danh sách key hợp lệ (đã hash)
  // Thêm key mới vào đây khi tạo key cho khách
  static final Map<String, String> _validKeys = {
    // Format: 'key' -> 'sha256 hash'
    // Key demo: MTAI-DEMO-KEY-0001
    'MTAI-DEMO-KEY-0001': _hashKey('MTAI-DEMO-KEY-0001'),
    'MTAI-DEMO-KEY-1002': _hashKey('MTAI-DEMO-KEY-1002'),
    // Thêm key thật ở đây
  };

  static String _hashKey(String key) {
    final input = '$_secretPrefix:${key.toUpperCase().trim()}';
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Kiểm tra key có hợp lệ không
  static LicenseResult validateKey(String key) {
    if (key.trim().isEmpty) {
      return LicenseResult(LicenseStatus.invalid, 'Vui lòng nhập key');
    }

    final normalizedKey = key.toUpperCase().trim();
    final hashedInput = _hashKey(normalizedKey);

    // Kiểm tra trong danh sách key hợp lệ
    final isValid = _validKeys.values.contains(hashedInput);

    if (isValid) {
      return LicenseResult(LicenseStatus.valid, 'Key hợp lệ');
    }

    return LicenseResult(LicenseStatus.invalid, 'Key không hợp lệ');
  }

  /// Lưu key đã kích hoạt
  static Future<void> saveLicense(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, key.toUpperCase().trim());
    await prefs.setString(_activatedAtKey, DateTime.now().toIso8601String());
  }

  /// Kiểm tra đã có license chưa
  static Future<bool> isLicensed() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString(_storageKey);

    if (savedKey == null || savedKey.isEmpty) return false;

    // Validate lại key đã lưu
    final result = validateKey(savedKey);
    return result.status == LicenseStatus.valid;
  }

  /// Lấy key đã lưu
  static Future<String?> getSavedKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_storageKey);
  }

  /// Xóa license (reset)
  static Future<void> clearLicense() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await prefs.remove(_activatedAtKey);
  }

  /// Tạo key mới (dùng để cấp key)
  /// Gọi từ admin tool hoặc command line
  static String generateKey() {
    final chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;
    final buffer = StringBuffer('MTAI-');

    for (int i = 0; i < 3; i++) {
      final segment = StringBuffer();
      for (int j = 0; j < 4; j++) {
        final index = (random + i * 4 + j) % chars.length;
        segment.write(chars[index]);
      }
      buffer.write(segment);
      if (i < 2) buffer.write('-');
    }

    return buffer.toString();
  }
}
