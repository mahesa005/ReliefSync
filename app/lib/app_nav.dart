import 'package:flutter/material.dart';

/// Global keys so background services (alarm polling) can open screens,
/// dialogs and snackbars from anywhere.
final navigatorKey = GlobalKey<NavigatorState>();
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<T?> pushScreen<T>(Widget screen) =>
    navigatorKey.currentState!.push<T>(MaterialPageRoute(builder: (_) => screen));
