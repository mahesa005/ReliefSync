import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api.dart';
import '../../services/location.dart';
import '../../theme.dart';
import '../../widgets/agency_sheet.dart';
import '../../widgets/common.dart';

/// Active task page for a volunteer (5.10): travel status, external navigation,
/// "relawan ke-N", the skill being fulfilled, and "Sudah teratasi" (the same vote
/// as the periodic popup, 5.11).
class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key, required this.assignmentId});
  final String assignmentId;

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  Json? _t;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
    // Share live coordinates while on a task (FR-8.5).
    context.read<LocationService>().startTracking();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await Api.instance.get('/assignments/${widget.assignmentId}') as Json;
      if (mounted) {
        setState(() {
          _t = t;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _t == null) setState(() => _error = e);
    }
  }

  Future<void> _setTravel(String status) async {
    final t = await Api.instance.post('/assignments/${widget.assignmentId}/travel-status', {'status': status}) as Json;
    setState(() => _t = t);
  }

  Future<void> _resolved() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Tandai sudah teratasi?'),
        content: const Text('Konfirmasi Anda dihitung bersama konfirmasi pelapor dan relawan lain. '
            'Status berubah "Selesai" setelah jumlah konfirmasi cukup.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ya, sudah teratasi')),
        ],
      ),
    );
    if (ok != true) return;
    await Api.instance.post('/reports/${_t!['report_id']}/vote', {'done': true});
    await _load();
    showMessage('Konfirmasi "sudah teratasi" tercatat.');
  }

  Future<void> _openMaps() async {
    final t = _t!;
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${t['lat']},${t['lng']}&travelmode=driving');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showMessage('Tidak dapat membuka aplikasi peta.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: const Text('Tugas saya')),
      floatingActionButton: t == null || t['report_status'] != 'active' ? null : AgencyFab(reportId: t['report_id'] as String),
      body: t == null
          ? Center(child: _error != null ? EmptyHint(icon: Icons.error_outline, text: '$_error') : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: _content(t)),
            ),
    );
  }

  List<Widget> _content(Json t) {
    final active = t['report_status'] == 'active' && t['status'] == 'aktif';
    final utama = t['role'] == 'utama';
    final travel = t['travel_status'] as String;
    final quorum = t['quorum'] as Json;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(16)),
                child: Text('#${t['order_number']}',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.primary)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Relawan ke-${t['order_number']} untuk ${t['skill']}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Pill(utama ? 'Bantuan Utama' : 'Bantuan Tambahan',
                      color: utama ? AppColors.primary : AppColors.info),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Text(t['incident_label'] as String, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${t['need_label']} · ${t['need_accepted']}/${t['need_quota']} relawan · '
                '${t['distance_km'] != null ? '${km(t['distance_km'])} lagi' : 'jarak belum diketahui'}',
                style: const TextStyle(color: AppColors.inkMuted, fontWeight: FontWeight.w600)),
            if ((t['raw_text'] as String).isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('"${t['raw_text']}"', style: Theme.of(context).textTheme.bodyLarge),
            ],
            if (t['address_text'] != null) ...[
              const SizedBox(height: 6),
              Text(t['address_text'] as String, style: const TextStyle(color: AppColors.inkMuted)),
            ],
            const SizedBox(height: 10),
            PhotoStrip(t['photo_urls'] as List),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              TrustBadge(t['reporter_trust'] as Json?),
              VerifierTrustBadge(t['reporter_verifier_trust'] as Json?),
              if (t['contact_phone_masked'] != null)
                Pill(t['contact_phone_masked'] as String, icon: Icons.phone_rounded),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: AppColors.ink),
        onPressed: _openMaps,
        icon: const Icon(Icons.navigation_rounded),
        label: const Text('Tunjukkan lokasi bencana'),
      ),
      const SizedBox(height: 20),
      if (!active)
        Card(
          color: AppColors.successSoft,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, color: AppColors.success),
              SizedBox(width: 10),
              Expanded(child: Text('Kejadian ini sudah dinyatakan selesai. Terima kasih atas bantuan Anda!',
                  style: TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ),
        )
      else ...[
        const SectionHeader('Status saya', subtitle: 'Pelapor melihat status dan posisi Anda secara langsung.'),
        _StatusOption(
          icon: Icons.directions_run_rounded,
          label: 'Masih di jalan',
          selected: travel == 'otw',
          onTap: travel == 'otw' ? null : () => _setTravel('otw'),
        ),
        const SizedBox(height: 8),
        _StatusOption(
          icon: Icons.place_rounded,
          label: 'Sudah sampai di lokasi',
          selected: travel == 'sampai',
          onTap: travel == 'sampai' ? null : () => _setTravel('sampai'),
        ),
        const SizedBox(height: 8),
        _StatusOption(
          icon: Icons.task_alt_rounded,
          label: t['my_vote_done'] == true ? 'Anda sudah konfirmasi teratasi' : 'Sudah teratasi',
          selected: t['my_vote_done'] == true,
          onTap: t['my_vote_done'] == true ? null : _resolved,
        ),
        const SizedBox(height: 16),
        _QuorumCard(quorum: quorum),
      ],
    ];
  }
}

class _StatusOption extends StatelessWidget {
  const _StatusOption({required this.icon, required this.label, required this.selected, this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap == null
            ? null
            : () async {
                try {
                  await onTap!();
                } catch (e) {
                  showError(e);
                }
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: 1.5),
          ),
          child: Row(children: [
            Icon(icon, color: selected ? Colors.white : AppColors.ink),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800, color: selected ? Colors.white : AppColors.ink)),
            ),
            if (selected) const Icon(Icons.check_rounded, color: Colors.white),
          ]),
        ),
      ),
    );
  }
}

class _QuorumCard extends StatelessWidget {
  const _QuorumCard({required this.quorum});
  final Json quorum;

  @override
  Widget build(BuildContext context) {
    final votes = quorum['votes'] as int;
    final required = quorum['required'] as int;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Konfirmasi selesai bersama', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          Text('$votes dari $required konfirmasi yang dibutuhkan · ${quorum['active']} orang aktif'
              '${(quorum['afk'] as int) > 0 ? ', ${quorum['afk']} tidak aktif' : ''}',
              style: const TextStyle(color: AppColors.inkMuted)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: required == 0 ? 0 : (votes / required).clamp(0, 1).toDouble(),
              backgroundColor: AppColors.line,
              color: AppColors.success,
            ),
          ),
        ]),
      ),
    );
  }
}
