import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_nav.dart';
import '../../services/api.dart';
import '../../services/session.dart';
import '../../services/sound.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/skill_picker.dart';

/// Activate the volunteer layer or edit skills (FR-1.4, 5.8). No radius is asked:
/// distance is scored automatically during matching.
class VolunteerOnboardingScreen extends StatefulWidget {
  const VolunteerOnboardingScreen({super.key});

  @override
  State<VolunteerOnboardingScreen> createState() => _VolunteerOnboardingScreenState();
}

class _VolunteerOnboardingScreenState extends State<VolunteerOnboardingScreen> {
  late final Session _session = context.read<Session>();
  late final bool _editing = _session.isVolunteer;
  late List<Json> _skills = [
    for (final s in (_session.volunteer?['skills'] as List? ?? []).cast<Json>())
      {'skill': s['skill'], 'evidence': s['evidence']},
  ];

  Future<void> _save() async {
    if (_skills.isEmpty) {
      showMessage('Pilih minimal satu kemampuan.', error: true);
      return;
    }
    final user = await Api.instance.post('/me/volunteer', {
      'skills': _skills,
      'is_active': _editing ? _session.isActiveVolunteer : true,
    }) as Json;
    _session.setUser(user);
    if (!mounted) return;
    Navigator.pop(context);
    if (!_editing) await showAlarmPermissionDialog();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Kemampuan saya' : 'Jadi relawan')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        if (!_editing) ...[
          Text('Bantu warga di sekitar Anda', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text(
            'Saat ada kejadian dalam radius 5 km yang membutuhkan kemampuan Anda, ReliefSync akan '
            'membunyikan alarm. Anda bebas menerima atau menolak, dan bisa menonaktifkan status relawan kapan saja.',
            style: TextStyle(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 20),
        ],
        const SectionHeader('Kemampuan Anda'),
        SkillPicker(skills: _skills, onChanged: (v) => setState(() => _skills = v)),
        const SizedBox(height: 28),
        BusyButton(
          label: _editing ? 'Simpan' : 'Aktifkan status relawan',
          icon: _editing ? Icons.save_rounded : Icons.volunteer_activism_rounded,
          onPressed: _save,
        ),
      ]),
    );
  }
}

/// After activation (5.8): explain alarms and let the volunteer test the sound.
Future<void> showAlarmPermissionDialog() async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  await showDialog<void>(
    context: ctx,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.notifications_active_rounded, color: AppColors.primary, size: 40),
      title: const Text('Izinkan alarm relawan'),
      content: const Text(
        'Permintaan prioritas tinggi akan berbunyi keras dan bergetar selama 30 detik, berbeda dari '
        'notifikasi biasa. Pastikan volume dan izin notifikasi aplikasi aktif.',
      ),
      actions: [
        TextButton(
          onPressed: () => Sound.instance.startAlarm(maxDuration: const Duration(seconds: 3)),
          child: const Text('Uji alarm'),
        ),
        FilledButton(
          onPressed: () {
            Sound.instance.stopAlarm();
            Navigator.pop(c);
          },
          child: const Text('Mengerti'),
        ),
      ],
    ),
  );
}
