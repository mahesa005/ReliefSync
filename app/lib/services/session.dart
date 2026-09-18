import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Logged-in user state. One account = base role (can always report); the
/// volunteer layer is optional (`user['volunteer']` is null until activated).
class Session extends ChangeNotifier {
  static const _tokenKey = 'auth_token';

  final Api api = Api.instance;
  Json? user;
  bool ready = false;

  bool get isLoggedIn => api.token != null && user != null;
  Json? get volunteer => user?['volunteer'] as Json?;
  bool get isVolunteer => volunteer != null;
  bool get isActiveVolunteer => volunteer?['is_active'] == true;
  String get firstName => ((user?['name'] as String?) ?? '').split(' ').first;

  Future<void> restore() async {
    await api.loadBaseUrl();
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString(_tokenKey);
    if (api.token != null) {
      try {
        user = await api.get('/me') as Json;
      } on ApiException catch (e) {
        if (e.statusCode == 401) await _clear();
      }
    }
    ready = true;
    notifyListeners();
  }

  /// Returns the simulated OTP (MVP) so the OTP screen can show it.
  Future<String?> register({
    required String name,
    required String phone,
    required String password,
    bool becomeVolunteer = false,
    List<Json> skills = const [],
  }) async {
    final res = await api.post('/auth/register', {
      'name': name,
      'phone': phone,
      'password': password,
      'become_volunteer': becomeVolunteer,
      'skills': skills,
    }) as Json;
    return res['dev_otp'] as String?;
  }

  Future<String?> resendOtp(String phone) async {
    final res = await api.post('/auth/resend-otp', {'phone': phone}) as Json;
    return res['dev_otp'] as String?;
  }

  Future<void> verifyOtp(String phone, String code) async {
    final res = await api.post('/auth/verify-otp', {'phone': phone, 'code': code}) as Json;
    await _signIn(res);
  }

  Future<void> login(String phone, String password) async {
    final res = await api.post('/auth/login', {'phone': phone, 'password': password}) as Json;
    await _signIn(res);
  }

  Future<void> _signIn(Json res) async {
    api.token = res['token'] as String;
    user = res['user'] as Json;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, api.token!);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (api.token == null) return;
    try {
      user = await api.get('/me') as Json;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 401) await logout();
    }
  }

  /// Applies an updated user payload returned by a /me endpoint.
  void setUser(Json value) {
    user = value;
    notifyListeners();
  }

  Future<void> logout() async {
    await _clear();
    notifyListeners();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
