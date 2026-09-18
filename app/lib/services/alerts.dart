import 'dart:async';

import 'package:flutter/material.dart';

import '../app_nav.dart';
import '../screens/volunteer/alarm_screen.dart';
import '../screens/volunteer/offer_sheet.dart';
import '../widgets/common.dart';
import '../widgets/prompts.dart';
import '../widgets/report_peek_sheet.dart';
import 'api.dart';
import 'sound.dart';

/// Polls the in-app notification inbox and the pending popups. This is what
/// makes alarms work without Firebase: the backend stores every notification
/// and the app picks it up within a few seconds (NFR-3). When FCM is
/// configured the same notifications also arrive as pushes.
///
/// * alarm           -> full-screen alarm with siren (AlarmScreen)
/// * standard        -> chime + banner, can be accepted proactively (FR-5.8)
/// * nearby          -> banner "Saya melihat kejadian ini" (5.7)
/// * confirm_prompt  -> "Apakah bencana ini sudah teratasi?" (5.11)
/// * accuracy_prompt -> "Apakah kondisi lapangan sesuai laporan?" (FR-7.3)
class AlertCenter extends ChangeNotifier {
  final Api api = Api.instance;

  Timer? _timer;
  int _lastId = 0;
  int unread = 0;

  /// Bumped on every new event so screens can refresh themselves.
  int version = 0;
  bool _polling = false;
  bool _dialogOpen = false;
  final Set<String> _alarmsShown = {};
  final Set<String> _promptsDismissed = {};
  int _tick = 0;

  Future<void> start() async {
    stop();
    try {
      final res = await api.get('/me/notifications', query: {'limit': 1}) as Json;
      final items = res['items'] as List;
      _lastId = items.isEmpty ? 0 : items.first['id'] as int;
      unread = res['unread'] as int;
    } catch (_) {}
    await _resumeActiveAlarm();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// If the app (re)starts during an active alarm, show it.
  Future<void> _resumeActiveAlarm() async {
    try {
      final reqs = await api.get('/volunteer/requests') as List;
      for (final r in reqs) {
        if (r['alarm_active'] == true && r['status'] == 'pending') {
          _showAlarm(r as Json);
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _poll() async {
    if (_polling || api.token == null) return;
    _polling = true;
    try {
      final res = await api.get('/me/notifications', query: {'after_id': _lastId}) as Json;
      unread = res['unread'] as int;
      final items = (res['items'] as List).cast<Json>().reversed.toList();
      if (items.isNotEmpty) {
        _lastId = items.last['id'] as int;
        version++;
        notifyListeners();
        for (final n in items) {
          await _handle(n);
        }
      }
      if (_tick++ % 2 == 0) await _checkPrompts();
    } catch (_) {
      // offline: try again next tick
    } finally {
      _polling = false;
    }
  }

  Future<void> _handle(Json n) async {
    final data = (n['data'] as Map?)?.cast<String, dynamic>() ?? {};
    switch (n['kind']) {
      case 'alarm':
        try {
          final offer = await api.get('/offers/${data['offer_id']}') as Json;
          if (offer['status'] == 'pending') _showAlarm(offer);
        } catch (_) {}
      case 'standard':
        Sound.instance.chime();
        showMessage(n['title'] as String,
            action: SnackBarAction(
                label: 'LIHAT', textColor: Colors.white, onPressed: () => openOffer(data['offer_id'] as String)));
      case 'nearby':
        Sound.instance.chime();
        showMessage(n['title'] as String,
            action: SnackBarAction(
                label: 'KONFIRMASI',
                textColor: Colors.white,
                onPressed: () => showReportPeek(data['report_id'] as String)));
      case 'confirm_prompt' || 'accuracy_prompt':
        break; // handled by _checkPrompts
      default:
        showMessage(n['title'] as String);
    }
  }

  void _showAlarm(Json offer) {
    final id = offer['offer_id'] as String;
    if (_alarmsShown.contains(id)) return;
    _alarmsShown.add(id);
    Sound.instance.startAlarm();
    pushScreen(AlarmScreen(offer: offer)).then((_) {
      Sound.instance.stopAlarm();
      version++;
      notifyListeners();
    });
  }

  Future<void> _checkPrompts() async {
    if (_dialogOpen) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    final res = await api.get('/me/prompts') as Json;
    final confirm = (res['confirm'] as List).cast<Json>();
    final accuracy = (res['accuracy'] as List).cast<Json>();
    for (final p in confirm) {
      final key = 'c:${p['report_id']}:${p['asked_at']}';
      if (_promptsDismissed.contains(key)) continue;
      _promptsDismissed.add(key);
      _dialogOpen = true;
      Sound.instance.chime();
      await showResolvedPrompt(p['report_id'] as String, p['address_text'] as String?);
      _dialogOpen = false;
      version++;
      notifyListeners();
      return;
    }
    for (final p in accuracy) {
      final key = 'a:${p['report_id']}';
      if (_promptsDismissed.contains(key)) continue;
      _promptsDismissed.add(key);
      _dialogOpen = true;
      await showAccuracyPrompt(p['report_id'] as String, p['raw_text'] as String?);
      _dialogOpen = false;
      return;
    }
  }

  Future<void> markAllRead() async {
    try {
      await api.post('/me/notifications/read', {'all': true});
      unread = 0;
      notifyListeners();
    } catch (_) {}
  }

  /// Nudge listeners (e.g. after the user acted on something).
  void bump() {
    version++;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
