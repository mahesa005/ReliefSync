import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/skill_picker.dart';
import 'otp_screen.dart';

/// Registration (5.1, FR-1.1 - FR-1.3): name, phone, password, and optionally
/// activate the volunteer status right away.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _volunteer = false;
  List<Json> _skills = [];

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (_name.text.trim().length < 2) throw ApiException(0, 'Isi nama lengkap.');
    if (_password.text.length < 6) throw ApiException(0, 'Kata sandi minimal 6 karakter.');
    if (_volunteer && _skills.isEmpty) throw ApiException(0, 'Pilih minimal satu kemampuan relawan.');
    final otp = await context.read<Session>().register(
          name: _name.text.trim(),
          phone: _phone.text,
          password: _password.text,
          becomeVolunteer: _volunteer,
          skills: _skills,
        );
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => OtpScreen(phone: _phone.text, devOtp: otp, becameVolunteer: _volunteer),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daftar')),
      body: ListView(padding: const EdgeInsets.fromLTRB(24, 4, 24, 32), children: [
        const Text('Satu akun untuk melapor dan (jika mau) menjadi relawan.',
            style: TextStyle(color: AppColors.inkMuted, fontSize: 15)),
        const SizedBox(height: 20),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nama lengkap', prefixIcon: Icon(Icons.person_outline_rounded)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Nomor HP',
            hintText: '08xxxxxxxxxx',
            prefixIcon: Icon(Icons.phone_iphone_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Kata sandi (min. 6 karakter)', prefixIcon: Icon(Icons.lock_outline_rounded)),
        ),
        const SizedBox(height: 20),
        Card(
          child: Column(children: [
            SwitchListTile(
              value: _volunteer,
              onChanged: (v) => setState(() => _volunteer = v),
              title: const Text('Aktifkan status relawan sekarang', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Opsional. Bisa diaktifkan nanti dari Profil.'),
            ),
            if (_volunteer)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SkillPicker(skills: _skills, onChanged: (v) => setState(() => _skills = v)),
              ),
          ]),
        ),
        const SizedBox(height: 24),
        BusyButton(label: 'Daftar & kirim kode OTP', onPressed: _register),
      ]),
    );
  }
}
