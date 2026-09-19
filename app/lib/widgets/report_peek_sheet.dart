import 'package:flutter/material.dart';

import '../app_nav.dart';
import '../screens/report/report_status_screen.dart';
import '../screens/volunteer/task_screen.dart';
import '../services/api.dart';
import '../theme.dart';
import 'agency_sheet.dart';
import 'common.dart';
import 'incident_icon.dart';

/// Detail of a report marker (map, nearby widget, nearby notification):
/// description, time since reported, "saya melihat kejadian ini", agency
/// contact, and -- for volunteers -- "partisipasi sebagai relawan" (5.4 / 5.7).
Future<void> showReportPeek(String reportId) async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  await showModalBottomSheet(
    context: ctx,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _ReportPeek(reportId: reportId),
  );
}

class _ReportPeek extends StatefulWidget {
  const _ReportPeek({required this.reportId});
  final String reportId;

  @override
  State<_ReportPeek> createState() => _ReportPeekState();
}

class _ReportPeekState extends State<_ReportPeek> {
  Json? _r;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.instance.get('/reports/${widget.reportId}') as Json;
      if (mounted) setState(() => _r = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _saw() async {
    final r = await Api.instance.post('/reports/${widget.reportId}/sightings') as Json;
    setState(() => _r = r);
    showMessage('Terima kasih, konfirmasi Anda tercatat.');
  }

  Future<void> _participate() async {
    final res = await Api.instance.post('/reports/${widget.reportId}/participate') as Json;
    if (!mounted) return;
    Navigator.pop(context);
    pushScreen(TaskScreen(assignmentId: res['assignment_id'] as String));
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (_error != null) {
      return SafeArea(child: EmptyHint(icon: Icons.error_outline, text: _error.toString()));
    }
    if (r == null) {
      return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
    }
    final isReporter = r['is_reporter'] == true;
    final assignment = r['my_assignment'] as Json?;
    final active = r['status'] == 'active';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(incidentIcon(r['incident_type'] as String?), color: AppColors.primary, size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text(r['incident_label'] as String, style: Theme.of(context).textTheme.titleLarge)),
            if (!active) const Pill('Selesai', color: AppColors.success),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            Pill('Dilaporkan ${durationSince(r['received_at'])} lalu', icon: Icons.schedule_rounded),
            if (r['distance_km'] != null) Pill('${km(r['distance_km'])} dari Anda', icon: Icons.near_me_rounded),
            TrustBadge(r['reporter_trust'] as Json?),
            VerifierTrustBadge(r['reporter_verifier_trust'] as Json?),
          ]),
          const SizedBox(height: 14),
          if ((r['raw_text'] as String).isNotEmpty)
            Text(r['raw_text'] as String, style: Theme.of(context).textTheme.bodyLarge),
          if (r['address_text'] != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.place_outlined, size: 18, color: AppColors.inkMuted),
              const SizedBox(width: 6),
              Expanded(child: Text(r['address_text'] as String, style: const TextStyle(color: AppColors.inkMuted))),
            ]),
          ],
          const SizedBox(height: 12),
          PhotoStrip(r['photo_urls'] as List),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: StatTile(value: '${r['sightings']}', label: 'orang melihat kejadian ini',
                icon: Icons.visibility_rounded)),
            const SizedBox(width: 10),
            Expanded(child: StatTile(value: '${r['accepted_total']}/${r['needs_total']}', label: 'relawan menuju',
                icon: Icons.directions_run_rounded, color: AppColors.success)),
          ]),
          const SizedBox(height: 16),
          if (isReporter)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                pushScreen(ReportStatusScreen(reportId: widget.reportId));
              },
              icon: const Icon(Icons.monitor_heart_outlined),
              label: const Text('Lihat status laporan'),
            )
          else if (active) ...[
            if (r['i_saw'] == true)
              const Pill('Anda sudah mengonfirmasi melihat kejadian ini', color: AppColors.success,
                  icon: Icons.check_circle_rounded)
            else
              BusyButton(label: 'Saya melihat kejadian ini juga', icon: Icons.visibility_rounded, onPressed: _saw),
            const SizedBox(height: 10),
            if (assignment != null)
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  pushScreen(TaskScreen(assignmentId: assignment['id'] as String));
                },
                icon: const Icon(Icons.assignment_turned_in_outlined),
                label: const Text('Buka tugas saya'),
              )
            else if (r['is_volunteer'] == true)
              BusyButton(
                  label: 'Partisipasi sebagai relawan',
                  icon: Icons.volunteer_activism_rounded,
                  color: AppColors.ink,
                  onPressed: _participate),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => showAgencySheet(context, reportId: widget.reportId),
            icon: const Icon(Icons.local_phone_outlined),
            label: const Text('Hubungi instansi resmi'),
          ),
        ]),
      ),
    );
  }
}
