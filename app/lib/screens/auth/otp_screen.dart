import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../profile/volunteer_onboarding_screen.dart';

/// Phone verification by OTP (FR-1.2). Simulated for the MVP: the backend
/// returns the code and it is shown here instead of being sent by SMS.
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.phone, this.devOtp, this.becameVolunteer = false});
  final String phone;
  final String? devOtp;
  final bool becameVolunteer;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _code = TextEditingController();
  late String? _devOtp = widget.devOtp;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    await context.read<Session>().verifyOtp(widget.phone, _code.text.trim());
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (widget.becameVolunteer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => showAlarmPermissionDialog());
    }
  }

  Future<void> _resend() async {
    final otp = await context.read<Session>().resendOtp(widget.phone);
    setState(() => _devOtp = otp);
    showMessage('Kode OTP baru telah dikirim.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verifikasi nomor HP')),
      body: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
        Text('Masukkan kode 6 digit yang dikirim ke ${widget.phone}.',
            style: const TextStyle(fontSize: 16, color: AppColors.inkMuted)),
        const SizedBox(height: 20),
        if (_devOtp != null)
          InkWell(
            onTap: () => _code.text = _devOtp!,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                const Icon(Icons.sms_outlined, color: AppColors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('OTP simulasi (MVP): $_devOtp — ketuk untuk mengisi',
                      style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 10),
          decoration: const InputDecoration(counterText: '', hintText: '••••••'),
        ),
        const SizedBox(height: 20),
        BusyButton(label: 'Verifikasi', onPressed: _verify),
        const SizedBox(height: 8),
        TextButton(onPressed: () => _resend().catchError(showError), child: const Text('Kirim ulang kode')),
      ]),
    );
  }
}
