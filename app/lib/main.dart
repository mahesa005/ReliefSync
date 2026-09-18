import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_nav.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/dashboard_screen.dart';
import 'services/alerts.dart';
import 'services/location.dart';
import 'services/session.dart';
import 'theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session();
  final location = LocationService();
  await location.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: location),
        ChangeNotifierProvider(create: (_) => AlertCenter()),
      ],
      child: const ReliefSyncApp(),
    ),
  );
  session.restore();
}

class ReliefSyncApp extends StatelessWidget {
  const ReliefSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ReliefSync',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: const _Root(),
    );
  }
}

/// Splash -> Login (not signed in) -> Dashboard.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (!session.ready) return const _Splash();
    if (!session.isLoggedIn) return const LoginScreen();
    return const DashboardScreen();
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.surface,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LogoMark(size: 88),
          SizedBox(height: 24),
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
        ]),
      ),
    );
  }
}
