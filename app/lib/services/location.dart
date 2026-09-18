import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Device location. Keeps the backend's "lokasi terbaru" fresh (matching,
/// FR-5.1) and powers live tracking of volunteers on the way (FR-8.5).
///
/// Emulators often have no GPS fix, so a "demo location" can be switched on in
/// Profile; it pins the device to the demo area in Jakarta.
class LocationService extends ChangeNotifier {
  static const demoCenter = LatLng(-6.1470, 106.8055);
  static const _demoKey = 'use_demo_location';

  LatLng? current;
  bool useDemoLocation = false;
  String? error;
  StreamSubscription<Position>? _sub;
  Timer? _heartbeat;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    useDemoLocation = prefs.getBool(_demoKey) ?? false;
    if (useDemoLocation) current = demoCenter;
  }

  Future<void> setDemoLocation(bool value) async {
    useDemoLocation = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_demoKey, value);
    if (value) {
      current = demoCenter;
      await _push();
    } else {
      await refresh();
    }
    notifyListeners();
  }

  /// Asks for permission if needed and returns the current position (or null).
  Future<LatLng?> refresh() async {
    if (useDemoLocation) {
      current = demoCenter;
      notifyListeners();
      return current;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        error = 'Layanan lokasi (GPS) tidak aktif.';
        notifyListeners();
        return current;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        error = 'Izin lokasi ditolak.';
        notifyListeners();
        return current;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
      );
      current = LatLng(pos.latitude, pos.longitude);
      error = null;
      notifyListeners();
      return current;
    } catch (e) {
      error = 'Lokasi tidak tersedia.';
      notifyListeners();
      return current;
    }
  }

  /// Start pushing location updates to the backend while logged in.
  Future<void> startTracking() async {
    await refresh();
    await _push();
    _sub?.cancel();
    if (!useDemoLocation) {
      try {
        _sub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 15),
        ).listen((pos) {
          if (useDemoLocation) return;
          current = LatLng(pos.latitude, pos.longitude);
          notifyListeners();
          _push();
        }, onError: (_) {});
      } catch (_) {}
    }
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => _push());
  }

  void stopTracking() {
    _sub?.cancel();
    _heartbeat?.cancel();
    _sub = null;
    _heartbeat = null;
  }

  Future<void> _push() async {
    final c = current;
    if (c == null || Api.instance.token == null) return;
    try {
      await Api.instance.post('/me/location', {'lat': c.latitude, 'lng': c.longitude});
    } catch (_) {}
  }

  @override
  void dispose() {
    stopTracking();
    super.dispose();
  }
}
