import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Audio + haptics. The alarm (batch 1, FR-5.6) is a looping two-tone siren
/// with repeated heavy vibration; standard notifications get a soft chime only.
/// They must feel clearly different, not just read differently (NFR-7).
class Sound {
  Sound._();
  static final Sound instance = Sound._();

  final AudioPlayer _alarm = AudioPlayer(playerId: 'alarm');
  final AudioPlayer _chime = AudioPlayer(playerId: 'chime');
  Timer? _vibration;
  Timer? _stopTimer;

  Future<void> startAlarm({Duration maxDuration = const Duration(seconds: 30)}) async {
    await stopAlarm();
    try {
      await _alarm.setReleaseMode(ReleaseMode.loop);
      await _alarm.play(AssetSource('sounds/alarm.wav'), volume: 1.0);
    } catch (_) {}
    _vibration = Timer.periodic(const Duration(milliseconds: 700), (_) => HapticFeedback.heavyImpact());
    _stopTimer = Timer(maxDuration, stopAlarm);
  }

  Future<void> stopAlarm() async {
    _vibration?.cancel();
    _stopTimer?.cancel();
    _vibration = null;
    try {
      await _alarm.stop();
    } catch (_) {}
  }

  Future<void> chime() async {
    HapticFeedback.mediumImpact();
    try {
      await _chime.play(AssetSource('sounds/chime.wav'), volume: 0.8);
    } catch (_) {}
  }
}
