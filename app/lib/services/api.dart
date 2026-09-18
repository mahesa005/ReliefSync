import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:shared_preferences/shared_preferences.dart';

typedef Json = Map<String, dynamic>;

/// Error with a user-facing (Indonesian) message taken from the API `detail`.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, [this.detail]);
  final int statusCode;
  final String message;
  final dynamic detail;

  @override
  String toString() => message;
}

/// Thin JSON client for the ReliefSync FastAPI backend.
///
/// Base URL: `--dart-define=API_BASE_URL=http://192.168.1.10:8000`, or changed
/// at runtime from the login screen ("Pengaturan server"). Defaults to the
/// host machine as seen from the Android emulator / iOS simulator.
class Api {
  Api._();
  static final Api instance = Api._();

  static const _prefsKey = 'api_base_url';
  static const _fromEnv = String.fromEnvironment('API_BASE_URL');

  String baseUrl = _defaultBaseUrl();
  String? token;

  static String _defaultBaseUrl() {
    if (_fromEnv.isNotEmpty) return _fromEnv;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8000';
    return 'http://localhost:8000';
  }

  Future<void> loadBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_prefsKey) ?? _defaultBaseUrl();
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, baseUrl);
  }

  /// Photo URLs from local storage are API-relative (`/uploads/...`).
  String resolve(String url) => url.startsWith('http') ? url : '$baseUrl$url';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final q = query?.map((k, v) => MapEntry(k, v?.toString()))?..removeWhere((_, v) => v == null);
    return Uri.parse('$baseUrl$path').replace(queryParameters: (q == null || q.isEmpty) ? null : q);
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => http.get(_uri(path, query), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) =>
      _send(() => http.post(_uri(path), headers: _headers, body: jsonEncode(body ?? {})));

  Future<dynamic> patch(String path, [Object? body]) =>
      _send(() => http.patch(_uri(path), headers: _headers, body: jsonEncode(body ?? {})));

  Future<dynamic> put(String path, [Object? body]) =>
      _send(() => http.put(_uri(path), headers: _headers, body: jsonEncode(body ?? {})));

  Future<String> uploadPhoto(String filePath) async {
    final req = http.MultipartRequest('POST', _uri('/uploads'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    final lower = filePath.toLowerCase();
    final subtype = lower.endsWith('.png') ? 'png' : (lower.endsWith('.webp') ? 'webp' : 'jpeg');
    req.files.add(await http.MultipartFile.fromPath('file', filePath,
        contentType: MediaType('image', subtype)));
    final res = await _send(() async => http.Response.fromStream(await req.send()));
    return (res as Json)['url'] as String;
  }

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      // A remote DB pooler occasionally needs a cold reconnect (backend-side
      // pool_recycle/warm-up keeps this rare, but network conditions vary),
      // so this has margin beyond the fast-path (usually well under 2s).
      res = await call().timeout(const Duration(seconds: 45));
    } catch (e) {
      throw ApiException(0, 'Tidak dapat terhubung ke server ($baseUrl). Periksa koneksi Anda.');
    }
    final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    throw ApiException(res.statusCode, _message(body), body is Map ? body['detail'] : null);
  }

  static String _message(dynamic body) {
    final detail = body is Map ? body['detail'] : null;
    if (detail is String) return detail;
    if (detail is Map && detail['message'] is String) return detail['message'] as String;
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map && first['msg'] != null) return 'Data tidak valid: ${first['msg']}';
    }
    return 'Terjadi kesalahan. Coba lagi.';
  }
}
