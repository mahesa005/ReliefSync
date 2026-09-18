import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import 'api.dart';

/// Push notifications (FCM) so alerts arrive while the app is closed; the
/// in-app polling in AlertCenter still covers the foreground case.
///
/// * `alarm`    -> arrives data-only and is rendered here: full-screen, keeps
///                 ringing (FLAG_INSISTENT) on the alarm audio stream until
///                 opened or `alarm_seconds` runs out.
/// * the rest   -> arrives with a `notification` payload that Android renders
///                 itself on the `relief_standard` channel.
///
/// Only Android is configured in Firebase: iOS push needs APNs, which needs a
/// paid Apple Developer account.
bool get pushSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

const _alarmChannel = AndroidNotificationChannel(
  'relief_alarm',
  'Alarm darurat',
  description: 'Permintaan relawan darurat. Berdering terus sampai dibuka.',
  importance: Importance.max,
  sound: RawResourceAndroidNotificationSound('alarm'),
  audioAttributesUsage: AudioAttributesUsage.alarm,
);

const _standardChannel = AndroidNotificationChannel(
  'relief_standard',
  'Notifikasi',
  description: 'Pembaruan laporan dan permintaan relawan biasa.',
  importance: Importance.high,
);

/// One fixed id: a newer alarm replaces the older one and it is easy to cancel.
const _alarmNotificationId = 911;

/// Android's Notification.FLAG_INSISTENT: repeat the sound until the user acts.
const _flagInsistent = 4;

final _local = FlutterLocalNotificationsPlugin();

Future<void> _initLocalNotifications() async {
  await _local.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_alarmChannel);
  await android?.createNotificationChannel(_standardChannel);
}

Future<void> _showAlarm(Map<String, dynamic> data) async {
  final seconds = int.tryParse('${data['alarm_seconds']}') ?? 30;
  await _local.show(
    id: _alarmNotificationId,
    title: data['title'] as String?,
    body: data['body'] as String?,
    payload: data['offer_id'] as String?,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _alarmChannel.id,
        _alarmChannel.name,
        channelDescription: _alarmChannel.description,
        importance: Importance.max,
        priority: Priority.max,
        sound: _alarmChannel.sound,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        fullScreenIntent: true,
        additionalFlags: Int32List.fromList([_flagInsistent]),
        timeoutAfter: seconds * 1000,
      ),
    ),
  );
}

/// Runs in a background isolate when a push arrives while the app is in the
/// background or closed.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  if (message.data['kind'] != 'alarm') return;
  await _initLocalNotifications();
  await _showAlarm(message.data);
}

class Push {
  Push._();

  static const _fullScreenAskedKey = 'push_full_screen_asked';
  static bool _registered = false;
  static AppLifecycleListener? _lifecycle;

  /// Call once from main(), before runApp.
  static Future<void> init() async {
    if (!pushSupported) return;
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      await _initLocalNotifications();
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
  }

  /// Call once signed in: asks for permissions and sends this device's token
  /// to the backend so it can push to it.
  static Future<void> register({required bool isVolunteer}) async {
    if (!pushSupported || Firebase.apps.isEmpty) return;
    await cancelAlarm();
    // The app is open, so the in-app AlarmScreen takes over from the ringing
    // notification whenever the user comes back to it.
    _lifecycle ??= AppLifecycleListener(onResume: cancelAlarm);
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      if (isVolunteer) await _askFullScreenOnce();
      final token = await messaging.getToken();
      if (token != null) await _sendToken(token);
      if (!_registered) {
        _registered = true;
        messaging.onTokenRefresh.listen(_sendToken);
      }
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  /// Invalidates this device's token on logout, so the previous account's
  /// alarms stop ringing here; the next login registers a fresh one.
  static Future<void> unregister() async {
    if (!pushSupported || Firebase.apps.isEmpty) return;
    await cancelAlarm();
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  static Future<void> cancelAlarm() async {
    if (!pushSupported) return;
    try {
      await _local.cancel(id: _alarmNotificationId);
    } catch (_) {}
  }

  /// Android 14+ only lets alarm/calling apps use full-screen notifications by
  /// default; others have to be allowed in Settings. Opening that screen on
  /// every launch would be obnoxious, so ask once per install.
  static Future<void> _askFullScreenOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_fullScreenAskedKey) ?? false) return;
    await prefs.setBool(_fullScreenAskedKey, true);
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestFullScreenIntentPermission();
  }

  static Future<void> _sendToken(String token) async {
    try {
      await Api.instance.post('/me/device-token', {'token': token});
    } catch (e) {
      debugPrint('Sending FCM token failed: $e');
    }
  }
}
