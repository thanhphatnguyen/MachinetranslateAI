import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_translate_config.dart';

class AppUser {
  final int id;
  final String email;
  final String displayName;
  final String role;
  final String status;
  final String serverUrl;
  final String sonioxApiKey;
  final String deviceId;

  AppUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    required this.status,
    required this.serverUrl,
    required this.sonioxApiKey,
    required this.deviceId,
  });

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: int.tryParse(map['id']?.toString() ?? '') ?? 0,
      email: map['email']?.toString() ?? '',
      displayName: map['display_name']?.toString() ?? '',
      role: map['role']?.toString() ?? 'user',
      status: map['status']?.toString() ?? 'active',
      serverUrl: map['server_url']?.toString() ?? '',
      sonioxApiKey: map['soniox_api_key']?.toString() ?? '',
      deviceId: map['device_id']?.toString() ?? '',
    );
  }

  Map<String, String> toPrefs() {
    return {
      'id': id.toString(),
      'email': email,
      'display_name': displayName,
      'role': role,
      'status': status,
      'server_url': serverUrl,
      'soniox_api_key': sonioxApiKey,
      'device_id': deviceId,
    };
  }
}

class AuthSession {
  final String token;
  final String apiBaseUrl;
  final AppUser user;

  AuthSession({
    required this.token,
    required this.apiBaseUrl,
    required this.user,
  });
}

class AuthService {
  static const defaultAdminApiUrl = 'http://103.118.29.243:8080';
  static const defaultConnectServerUrl = 'http://103.118.29.243:3000';
  static const defaultSonioxApiKey =
      '8dfa5a83f387ffadf2ce3b0d04c90d88b61c077c9e40fefcb1084bfaa39264c2';

  static const _tokenKey = 'app_auth_token';
  static const _apiBaseUrlKey = 'app_auth_api_base_url';
  static const _userJsonKey = 'app_auth_user_json';

  AuthSession? _session;

  AuthSession? get session => _session;
  bool get isAuthenticated => _session != null;

  Future<AuthSession?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey) ?? '';
    final apiBaseUrl = prefs.getString(_apiBaseUrlKey) ?? '';
    final userJson = prefs.getString(_userJsonKey) ?? '';

    if (token.isEmpty || apiBaseUrl.isEmpty || userJson.isEmpty) {
      _session = null;
      return null;
    }

    try {
      final user = AppUser.fromMap(
        Map<String, dynamic>.from(jsonDecode(userJson) as Map),
      );
      _session = AuthSession(token: token, apiBaseUrl: apiBaseUrl, user: user);
      await refreshConfig();
      return _session;
    } catch (_) {
      await logout();
      return null;
    }
  }

  Future<AuthSession> login({
    required String apiBaseUrl,
    required String email,
    required String password,
  }) async {
    return _authenticate(
      path: '/api/app/login',
      apiBaseUrl: apiBaseUrl,
      body: {'email': email.trim(), 'password': password},
    );
  }

  Future<AuthSession> register({
    required String apiBaseUrl,
    required String email,
    required String password,
    required String displayName,
  }) async {
    return _authenticate(
      path: '/api/app/register',
      apiBaseUrl: apiBaseUrl,
      body: {
        'email': email.trim(),
        'password': password,
        'display_name': displayName.trim(),
        'server_url': defaultConnectServerUrl,
        'soniox_api_key': defaultSonioxApiKey,
      },
    );
  }

  Future<void> signInWithGoogle() async {
    throw UnsupportedError(
      'Google Sign-In needs Firebase/OAuth configuration first.',
    );
  }

  Future<AuthSession> _authenticate({
    required String path,
    required String apiBaseUrl,
    required Map<String, String> body,
  }) async {
    final normalizedBaseUrl = _normalizeBaseUrl(apiBaseUrl);
    late http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$normalizedBaseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
    } on SocketException {
      throw Exception(
        'Cannot connect to Admin API. Use the VPS/PC LAN IP, not localhost. Example: http://192.168.1.10:8080',
      );
    } on http.ClientException {
      throw Exception(
        'Cannot connect to Admin API. Check the URL, server process, and firewall.',
      );
    } on HttpException {
      throw Exception('Admin API returned an invalid HTTP response.');
    } on FormatException {
      throw Exception('Admin API URL is invalid.');
    } on TimeoutException {
      throw Exception('Connection timed out. Check VPS firewall and port 8080.');
    }
    final data = _decodeResponse(response);
    final user = AppUser.fromMap(Map<String, dynamic>.from(data['user'] as Map));
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw Exception('Server did not return an auth token');
    }

    _session = AuthSession(
      token: token,
      apiBaseUrl: normalizedBaseUrl,
      user: user,
    );
    await _saveSession(_session!);
    await _applyAdminConfig(
      serverUrl: user.serverUrl,
      sonioxApiKey: user.sonioxApiKey,
    );
    return _session!;
  }

  Future<void> refreshConfig() async {
    final current = _session;
    if (current == null) return;

    final response = await http.get(
      Uri.parse('${current.apiBaseUrl}/api/app/me/config'),
      headers: {'Authorization': 'Bearer ${current.token}'},
    );
    final data = _decodeResponse(response);
    final user = AppUser.fromMap(Map<String, dynamic>.from(data['user'] as Map));
    _session = AuthSession(
      token: current.token,
      apiBaseUrl: current.apiBaseUrl,
      user: user,
    );
    await _saveSession(_session!);
    await _applyAdminConfig(
      serverUrl: data['server_url']?.toString() ?? user.serverUrl,
      sonioxApiKey: data['soniox_api_key']?.toString() ?? user.sonioxApiKey,
    );
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userJsonKey);
    _session = null;
  }

  Future<String> savedApiBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_apiBaseUrlKey) ?? '';
    return saved.isEmpty ? defaultAdminApiUrl : saved;
  }

  Future<void> _saveSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, session.token);
    await prefs.setString(_apiBaseUrlKey, session.apiBaseUrl);
    await prefs.setString(_userJsonKey, jsonEncode(session.user.toPrefs()));
  }

  Future<void> _applyAdminConfig({
    required String serverUrl,
    required String sonioxApiKey,
  }) async {
    final url = serverUrl.trim().isEmpty
        ? defaultConnectServerUrl
        : serverUrl.trim();
    final key = sonioxApiKey.trim().isEmpty
        ? defaultSonioxApiKey
        : sonioxApiKey.trim();
    final config = AiTranslateConfig();
    await config.load();
    config.serverUrl = url;
    config.proSttApiKey = key;
    await config.save();
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final body = response.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['detail']?.toString() ?? 'Request failed');
    }
    return body;
  }

  String _normalizeBaseUrl(String value) {
    var url = value.trim();
    if (url.isEmpty) {
      throw Exception('Admin API URL is required');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
