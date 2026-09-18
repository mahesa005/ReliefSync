import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/alerts.dart';
import '../../services/api.dart';
import '../../services/location.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'volunteer_onboarding_screen.dart';

/// Profile (5.3): identity (masked phone), trust tier, the optional volunteer
/// layer (toggle, skills, statistics), notification preference and demo tools.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    context.read<Session>().refresh();
  }

  Future<void> _patch(String path, Json body, {bool isPatch = true}) async {
    try {
      final user = await (isPatch ? Api.instance.patch(path, body) : Api.instance.post(path, body)) as Json;
      if (mounted) context.read<Session>().setUser(user);
    } catch (e) {
      showError(e);
    }
  }

  Future<void> _relocateSims() async {
    final loc = await context.read<LocationService>().refresh();
    if (loc == null) {
      showMessage('Lokasi Anda belum tersedia.', error: true);
      return;
    }
    final res = await Api.instance.post('/demo/relocate-sims', {'lat': loc.latitude, 'lng': loc.longitude}) as Json;
    showMessage('${res['moved']} relawan simulasi dipindahkan ke sekitar Anda.');
  }

  Future<void> _logout() async {
    context.read<AlertCenter>().stop();
    context.read<LocationService>().stopTracking();
    await context.read<Session>().logout();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final location = context.watch<LocationService>();
    final user = session.user;
    if (user == null) return const Scaffold();
    final v = session.volunteer;
    final name = user['name'] as String;
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: AppColors.primarySoft,
                child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.primary)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: Theme.of(context).textTheme.titleLarge),
                  Text(user['phone_masked'] as String? ?? '', style: const TextStyle(color: AppColors.inkMuted)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    TrustBadge(user['trust'] as Json?),
                    if (v != null)
                      Pill(v['is_active'] == true ? 'Relawan aktif' : 'Relawan nonaktif',
                          color: v['is_active'] == true ? AppColors.success : AppColors.inkMuted),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('Tingkat kepercayaan pelapor dihitung dari kesesuaian laporan Anda dengan kondisi lapangan.',
              style: TextStyle(color: AppColors.inkMuted, fontSize: 12.5)),
        ),
        const SizedBox(height: 20),
        if (v == null)
          Card(
            color: AppColors.primarySoft,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Jadi relawan', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('Bantu warga di sekitar Anda saat terjadi bencana. Anda tetap bisa melapor seperti biasa.'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const VolunteerOnboardingScreen())),
                  icon: const Icon(Icons.volunteer_activism_rounded),
                  label: const Text('Aktifkan status relawan'),
                ),
              ]),
            ),
          )
        else
          ..._volunteerSection(v),
        const SizedBox(height: 20),
        const SectionHeader('Pengaturan'),
        Card(
          child: Column(children: [
            SwitchListTile(
              value: user['notify_nearby'] == true,
              onChanged: (value) => _patch('/me', {'notify_nearby': value}),
              title: const Text('Permintaan konfirmasi kejadian sekitar',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Tanya saya jika ada laporan di dekat saya. Anda tetap bisa melapor.'),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        const SectionHeader('Mode demo', subtitle: 'Untuk presentasi dengan data relawan simulasi.'),
        Card(
          child: Column(children: [
            SwitchListTile(
              value: location.useDemoLocation,
              onChanged: (value) => location.setDemoLocation(value),
              title: const Text('Gunakan lokasi demo (Jakarta)', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Untuk emulator tanpa GPS.'),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.groups_rounded),
              title: const Text('Sebar relawan simulasi di sekitar saya', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Memindahkan ±30 relawan simulasi ke radius 5 km dari lokasi Anda.'),
              onTap: () => _relocateSims().catchError(showError),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(Api.instance.baseUrl),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Keluar'),
        ),
      ]),
    );
  }

  List<Widget> _volunteerSection(Json v) {
    final skills = (v['skills'] as List).cast<Json>();
    final stats = v['stats'] as Json? ?? {};
    final perSkill = (stats['per_skill'] as Map?)?.cast<String, dynamic>() ?? {};
    final rate = stats['completion_rate'];
    final fires = ((v['disaster_experience'] as Map?)?['kebakaran'] ?? 0) as int;
    return [
      Card(
        child: SwitchListTile(
          value: v['is_active'] == true,
          onChanged: (value) => _patch('/me/volunteer/active', {'is_active': value}),
          title: const Text('Status relawan aktif', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: const Text('Nonaktifkan untuk berhenti menerima permintaan sementara.'),
        ),
      ),
      const SizedBox(height: 16),
      SectionHeader('Kemampuan',
          trailing: TextButton(
            onPressed: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const VolunteerOnboardingScreen())),
            child: const Text('Ubah'),
          )),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in skills)
          Chip(
            avatar: Icon(s['evidence'] == 'certified' ? Icons.verified_rounded : Icons.shield_outlined,
                size: 18, color: s['evidence'] == 'certified' ? AppColors.success : AppColors.inkMuted),
            label: Text('${s['skill']}  ·  ${perSkill[s['skill']] ?? 0}x'),
          ),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: StatTile(value: '${stats['participations'] ?? 0}', label: 'bencana diikuti',
            icon: Icons.local_fire_department_outlined, color: AppColors.primary)),
        const SizedBox(width: 10),
        Expanded(child: StatTile(value: '${v['completion_count']}', label: 'tugas utama selesai',
            icon: Icons.task_alt_rounded, color: AppColors.success)),
        const SizedBox(width: 10),
        Expanded(child: StatTile(value: rate == null ? '-' : '${((rate as num) * 100).round()}%',
            label: 'selesai tanpa AFK', icon: Icons.timer_outlined, color: AppColors.info)),
      ]),
      const SizedBox(height: 8),
      Text('Pengalaman kebakaran tercatat: $fires kejadian.',
          style: const TextStyle(color: AppColors.inkMuted, fontSize: 13)),
    ];
  }
}
