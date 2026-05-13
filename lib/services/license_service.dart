import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LicenseStatus { valid, invalid, expired, notActivated, deviceMismatch }

class LicenseResult {
  final LicenseStatus status;
  final String? message;

  LicenseResult(this.status, [this.message]);
}

class LicenseService {
  static const _storageKey = 'ai_translate_license_key';
  static const _activatedAtKey = 'ai_translate_license_activated_at';
  static const _deviceIdKey = 'ai_translate_license_device_id';

  // Prefix bí mật để hash - chỉ bạn biết
  static const _secretPrefix = 'MTAI-2026';

  // Danh sách key hợp lệ (đã hash)
  // Thêm key mới vào đây khi tạo key cho khách
  static final Map<String, String> _validKeys = {
    // Format: 'key' -> 'sha256 hash'
    // Key demo: MTAI-DEMO-KEY-0001
    'MTAI-DEMO-KEY-0001': _hashKey('MTAI-DEMO-KEY-0001'),
    'MTAI-DEMO-KEY-1002': _hashKey('MTAI-DEMO-KEY-1002'),
    'MTAI-DEMO-KEY-A1A1': _hashKey('MTAI-DEMO-KEY-A1A1'),
    'MTAI-DEMO-KEY-X9A2': _hashKey('MTAI-DEMO-KEY-X9A2'),
    'MTAI-DEMO-KEY-Q7M4': _hashKey('MTAI-DEMO-KEY-Q7M4'),
    'MTAI-DEMO-KEY-PL8K': _hashKey('MTAI-DEMO-KEY-PL8K'),
    'MTAI-DEMO-KEY-7BZ1': _hashKey('MTAI-DEMO-KEY-7BZ1'),
    'MTAI-DEMO-KEY-R2XD': _hashKey('MTAI-DEMO-KEY-R2XD'),
    'MTAI-DEMO-KEY-MN5Q': _hashKey('MTAI-DEMO-KEY-MN5Q'),
    'MTAI-DEMO-KEY-T4CY': _hashKey('MTAI-DEMO-KEY-T4CY'),
    'MTAI-DEMO-KEY-K8WP': _hashKey('MTAI-DEMO-KEY-K8WP'),
    'MTAI-DEMO-KEY-D3LF': _hashKey('MTAI-DEMO-KEY-D3LF'),
    'MTAI-DEMO-KEY-Z7VN': _hashKey('MTAI-DEMO-KEY-Z7VN'),
    'MTAI-DEMO-KEY-H2RT': _hashKey('MTAI-DEMO-KEY-H2RT'),
    'MTAI-DEMO-KEY-B9XM': _hashKey('MTAI-DEMO-KEY-B9XM'),
    'MTAI-DEMO-KEY-J5QC': _hashKey('MTAI-DEMO-KEY-J5QC'),
    'MTAI-DEMO-KEY-V4PK': _hashKey('MTAI-DEMO-KEY-V4PK'),
    'MTAI-DEMO-KEY-N8DZ': _hashKey('MTAI-DEMO-KEY-N8DZ'),
    'MTAI-DEMO-KEY-C1YW': _hashKey('MTAI-DEMO-KEY-C1YW'),
    'MTAI-DEMO-KEY-F6TR': _hashKey('MTAI-DEMO-KEY-F6TR'),
    'MTAI-DEMO-KEY-L9BX': _hashKey('MTAI-DEMO-KEY-L9BX'),
    'MTAI-DEMO-KEY-P3KV': _hashKey('MTAI-DEMO-KEY-P3KV'),
    'MTAI-DEMO-KEY-W7HF': _hashKey('MTAI-DEMO-KEY-W7HF'),
    // Thêm key thật ở đây
  };

  static String _hashKey(String key) {
    final input = '$_secretPrefix:${key.toUpperCase().trim()}';
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Lấy device ID unique cho thiết bị hiện tại
  static Future<String> getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    String deviceId;

    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      deviceId = androidInfo.id; // Android ID
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      deviceId = iosInfo.identifierForVendor ?? 'unknown';
    } else if (Platform.isWindows) {
      final windowsInfo = await deviceInfo.windowsInfo;
      deviceId = windowsInfo.deviceId;
    } else if (Platform.isMacOS) {
      final macInfo = await deviceInfo.macOsInfo;
      deviceId = macInfo.systemGUID ?? 'unknown';
    } else if (Platform.isLinux) {
      final linuxInfo = await deviceInfo.linuxInfo;
      deviceId = linuxInfo.machineId ?? 'unknown';
    } else {
      deviceId = 'unsupported';
    }

    return deviceId;
  }

  /// Kiểm tra key có hợp lệ không (chỉ validate format)
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

  /// Lưu key đã kích hoạt + deviceId
  static Future<void> saveLicense(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final deviceId = await getDeviceId();

    await prefs.setString(_storageKey, key.toUpperCase().trim());
    await prefs.setString(_activatedAtKey, DateTime.now().toIso8601String());
    await prefs.setString(_deviceIdKey, deviceId);
  }

  /// Kiểm tra đã có license chưa (bao gồm device binding)
  static Future<bool> isLicensed() async {
    final result = await checkLicense();
    return result.status == LicenseStatus.valid;
  }

  /// Kiểm tra license chi tiết (trả về status cụ thể)
  static Future<LicenseResult> checkLicense() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString(_storageKey);

    // Chưa có key
    if (savedKey == null || savedKey.isEmpty) {
      return LicenseResult(LicenseStatus.notActivated, 'Chưa kích hoạt');
    }

    // Validate key
    final keyResult = validateKey(savedKey);
    if (keyResult.status != LicenseStatus.valid) {
      return keyResult;
    }

    // Kiểm tra device binding
    final savedDeviceId = prefs.getString(_deviceIdKey);
    final currentDeviceId = await getDeviceId();

    if (savedDeviceId == null || savedDeviceId != currentDeviceId) {
      return LicenseResult(
        LicenseStatus.deviceMismatch,
        'Key đã được sử dụng trên thiết bị khác',
      );
    }

    return LicenseResult(LicenseStatus.valid, 'License hợp lệ');
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
    await prefs.remove(_deviceIdKey);
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
