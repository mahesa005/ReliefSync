import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../theme.dart';
import 'common.dart';

/// Official agency contact (FR-10.1 - 10.3). "Call" opens the native dialer via a
/// `tel:` URI (NFR-8). Calling never marks the incident as officially handled
/// (FR-10.4) -- that is a separate manual status on the report page.
Future<void> showAgencySheet(BuildContext context,
    {String? reportId, double? lat, double? lng, String incidentType = 'lainnya'}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (_) => _AgencySheet(reportId: reportId, lat: lat, lng: lng, incidentType: incidentType),
  );
}

Future<void> callNumber(String phone) async {
  final ok = await launchUrl(Uri(scheme: 'tel', path: phone));
  if (!ok) showMessage('Tidak dapat membuka aplikasi telepon. Hubungi $phone secara manual.', error: true);
}

class _AgencySheet extends StatefulWidget {
  const _AgencySheet({this.reportId, this.lat, this.lng, required this.incidentType});
  final String? reportId;
  final double? lat;
  final double? lng;
  final String incidentType;

  @override
  State<_AgencySheet> createState() => _AgencySheetState();
}

class _AgencySheetState extends State<_AgencySheet> {
  Json? _data;
  Object? _error;
  bool _showOthers = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await Api.instance.get('/agencies/suggest', query: {
        'report_id': widget.reportId,
        'lat': widget.lat,
        'lng': widget.lng,
        'incident_type': widget.incidentType,
      }) as Json;
      setState(() => _data = data);
    } catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = _data?['primary'] as Json?;
    final others = (_data?['others'] as List?)?.cast<Json>() ?? [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Hubungi instansi resmi', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Saran berdasarkan jenis kejadian dan lokasi.', style: TextStyle(color: AppColors.inkMuted)),
          const SizedBox(height: 16),
          if (_error != null)
            // Offline fallback: the national emergency number always works.
            _AgencyTile(agency: const {'name': 'Layanan Darurat', 'phone': '112', 'description': 'Nomor darurat nasional.'},
                primary: true)
          else if (_data == null)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else ...[
            if (primary != null) _AgencyTile(agency: primary, primary: true),
            const SizedBox(height: 12),
            if (others.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _showOthers = !_showOthers),
                icon: Icon(_showOthers ? Icons.expand_less : Icons.expand_more),
                label: Text(_showOthers ? 'Sembunyikan instansi lain' : 'Lihat instansi lain (${others.length})'),
              ),
            if (_showOthers)
              ...others.map((a) => Padding(padding: const EdgeInsets.only(top: 8), child: _AgencyTile(agency: a))),
          ],
          const SizedBox(height: 12),
          const Text(
            'Menekan "Telepon" tidak otomatis menandai kejadian sudah ditangani instansi resmi.',
            style: TextStyle(color: AppColors.inkMuted, fontSize: 12.5),
          ),
        ]),
      ),
    );
  }
}

class _AgencyTile extends StatelessWidget {
  const _AgencyTile({required this.agency, this.primary = false});
  final Json agency;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final phone = agency['phone'] as String;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary ? AppColors.primary.withValues(alpha: 0.3) : AppColors.line),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (primary) const Pill('Saran utama', color: AppColors.primary),
            if (primary) const SizedBox(height: 6),
            Text(agency['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text(agency['description'] as String? ?? '', style: const TextStyle(color: AppColors.inkMuted, fontSize: 13.5)),
          ]),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            backgroundColor: primary ? AppColors.primary : AppColors.ink,
          ),
          onPressed: () => callNumber(phone),
          icon: const Icon(Icons.call_rounded),
          label: Text(phone),
        ),
      ]),
    );
  }
}

/// Floating "Hubungi instansi" button that stays on screen while a report is
/// being made or is active (5.6).
class AgencyFab extends StatelessWidget {
  const AgencyFab({super.key, this.reportId, this.lat, this.lng});
  final String? reportId;
  final double? lat;
  final double? lng;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      heroTag: 'agency-fab',
      backgroundColor: AppColors.ink,
      foregroundColor: Colors.white,
      onPressed: () => showAgencySheet(context, reportId: reportId, lat: lat, lng: lng),
      icon: const Icon(Icons.local_phone_rounded),
      label: const Text('Instansi resmi', style: TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}
