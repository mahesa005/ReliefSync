import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'otp_screen.dart';
import 'register_screen.dart';

/// Login with phone number + password (5.1).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final session = context.read<Session>();
    try {
      await session.login(_phone.text, _password.text);
    } on ApiException catch (e) {
      // Registered but not verified yet -> continue with OTP.
      if (e.statusCode == 403 && e.detail is Map && mounted) {
        final detail = e.detail as Map;
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => OtpScreen(phone: detail['phone'] as String, devOtp: detail['dev_otp'] as String?),
        ));
        return;
      }
      rethrow;
    }
  }

  void _fillDemo(String phone) {
    _phone.text = phone;
    _password.text = 'demo1234';
  }

  Future<void> _serverSettings() async {
    final controller = TextEditingController(text: Api.instance.baseUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Pengaturan server'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Alamat backend ReliefSync. Untuk HP fisik, gunakan IP laptop di jaringan yang sama.',
              style: TextStyle(color: AppColors.inkMuted)),
          const SizedBox(height: 12),
          TextField(controller: controller, keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'http://192.168.1.10:8000')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Simpan')),
        ],
      ),
    );
    if (url != null && url.trim().isNotEmpty) {
      await Api.instance.setBaseUrl(url);
      setState(() {});
      showMessage('Server: ${Api.instance.baseUrl}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(tooltip: 'Pengaturan server', onPressed: _serverSettings, icon: const Icon(Icons.settings_outlined)),
      ]),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [
          const SizedBox(height: 8),
          const Center(child: LogoFull(height: 56)),
          const SizedBox(height: 12),
          const Text('Relawan terdekat, tepat saat dibutuhkan.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkMuted, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 36),
          Text('Masuk', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(labelText: 'Nomor HP', prefixIcon: Icon(Icons.phone_iphone_rounded)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Kata sandi',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              ),
            ),
            onSubmitted: (_) => _login().catchError(showError),
          ),
          const SizedBox(height: 20),
          BusyButton(label: 'Masuk', onPressed: _login),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
            child: const Text('Belum punya akun? Daftar'),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.infoSoft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Akun demo', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.info)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ActionChip(label: const Text('Pelapor · 081200000001'), onPressed: () => _fillDemo('081200000001')),
                ActionChip(label: const Text('Relawan · 081200000002'), onPressed: () => _fillDemo('081200000002')),
              ]),
              const SizedBox(height: 6),
              const Text('Kata sandi: demo1234', style: TextStyle(color: AppColors.info, fontSize: 13)),
            ]),
          ),
        ]),
      ),
    );
  }
}
