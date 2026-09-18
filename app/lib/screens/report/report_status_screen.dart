import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/api.dart';
import '../../theme.dart';
import '../../widgets/agency_sheet.dart';
import '../../widgets/common.dart';
import '../../widgets/incident_icon.dart';
import '../../widgets/map_tiles.dart';
import '../map/map_screen.dart';

/// Reporter's live status page (5.6, FR-2.6, FR-2.7, FR-8.1, FR-8.4, FR-8.5):
/// volunteers contacted, who accepted and where they are, sightings by other
/// users, collective "selesai" confirmation and official-agency status.
/// Refreshes every 4 s without manual reload (FR-8.3 / NFR-3).
class ReportStatusScreen extends StatefulWidget {
  const ReportStatusScreen({super.key, required this.reportId});
  final String reportId;

  @override
  State<ReportStatusScreen> createState() => _ReportStatusScreenState();
}

class _ReportStatusScreenState extends State<ReportStatusScreen> {
  Json? _r;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Api.instance.get('/reports/${widget.reportId}') as Json;
      if (mounted) {
        setState(() {
          _r = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _r == null) setState(() => _error = e);
    }
  }

  Future<void> _vote() async {
    final r = await Api.instance.post('/reports/${widget.reportId}/vote', {'done': true}) as Json;
    setState(() => _r = r);
    showMessage(r['status'] == 'resolved' ? 'Kejadian dinyatakan selesai.' : 'Konfirmasi Anda tercatat.');
  }

  Future<void> _setOfficial(String status) async {
    final r = await Api.instance.post('/reports/${widget.reportId}/official-status', {'status': status}) as Json;
    setState(() => _r = r);
  }

  Future<void> _release(Json v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Lepas ${v['name']}?'),
        content: const Text('Relawan ini tidak lagi dihitung untuk kebutuhan ini. '
            'Sistem akan menawarkan ke relawan lain jika kuota belum terpenuhi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lepas')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await Api.instance.post('/assignments/${v['assignment_id']}/release') as Json;
      setState(() => _r = r);
    } catch (e) {
      showError(e);
    }
  }

  void _openMap({LatLng? focus}) {
    final r = _r!;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapScreen(
          focus: focus ?? pointOf(r),
          trackReportId: widget.reportId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final active = r?['status'] == 'active';
    return Scaffold(
      appBar: AppBar(title: const Text('Status laporan')),
      floatingActionButton: active ? AgencyFab(reportId: widget.reportId) : null,
      body: r == null
          ? Center(child: _error != null ? EmptyHint(icon: Icons.error_outline, text: '$_error') : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 110), children: _content(r)),
            ),
    );
  }

  List<Widget> _content(Json r) {
    final active = r['status'] == 'active';
    final needs = (r['needs'] as List).cast<Json>();
    final volunteers = (r['volunteers'] as List? ?? []).cast<Json>();
    final quorum = r['quorum'] as Json?;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(r['incident_label'] as String, style: Theme.of(context).textTheme.titleLarge)),
              active
                  ? const Pill('Aktif', color: AppColors.primary, icon: Icons.circle)
                  : const Pill('Selesai', color: AppColors.success, icon: Icons.check_circle_rounded),
            ]),
            const SizedBox(height: 4),
            Text('Dilaporkan ${timeAgo(r['received_at'])}'
                '${r['address_text'] != null ? ' · ${r['address_text']}' : ''}',
                style: const TextStyle(color: AppColors.inkMuted)),
            if (!active) ...[
              const SizedBox(height: 10),
              Text(r['resolved_by'] == 'timeout'
                  ? 'Otomatis selesai setelah 24 jam.'
                  : 'Dinyatakan selesai lewat konfirmasi bersama. Terima kasih!',
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.success)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: StatTile(value: '${r['contacted_total']}', label: 'relawan sedang dihubungi',
            icon: Icons.notifications_active_outlined, color: AppColors.primary)),
        const SizedBox(width: 10),
        Expanded(child: StatTile(value: '${r['accepted_total']}/${r['needs_total']}', label: 'relawan bersedia',
            icon: Icons.directions_run_rounded, color: AppColors.success)),
        const SizedBox(width: 10),
        Expanded(child: StatTile(value: '${r['sightings']}', label: 'warga melihat kejadian',
            icon: Icons.visibility_outlined, color: AppColors.info)),
      ]),
      const SizedBox(height: 12),
      _LiveMap(report: r, volunteers: volunteers, onTap: () => _openMap()),
      const SizedBox(height: 20),
      const SectionHeader('Kebutuhan bantuan'),
      for (final n in needs) _NeedCard(need: n),
      const SizedBox(height: 12),
      SectionHeader('Relawan yang menuju lokasi', subtitle: volunteers.isEmpty ? null : 'Ketuk untuk melihat di peta'),
      if (volunteers.isEmpty)
        const Card(child: EmptyHint(icon: Icons.hourglass_top_rounded, text: 'Menunggu relawan menerima permintaan...'))
      else
        Card(
          child: Column(children: [
            for (var i = 0; i < volunteers.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _VolunteerTile(
                v: volunteers[i],
                onTap: volunteers[i]['lat'] == null
                    ? null
                    : () => _openMap(focus: pointOf(volunteers[i])),
                onRelease: active && volunteers[i]['status'] == 'aktif' ? () => _release(volunteers[i]) : null,
              ),
            ],
          ]),
        ),
      if (quorum != null && active) ...[
        const SizedBox(height: 20),
        const SectionHeader('Apakah sudah teratasi?',
            subtitle: 'Status selesai butuh konfirmasi dari beberapa orang yang terlibat.'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${quorum['votes']} dari ${quorum['required']} konfirmasi · ${quorum['active']} orang aktif',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: (quorum['required'] as int) == 0
                      ? 0
                      : ((quorum['votes'] as int) / (quorum['required'] as int)).clamp(0, 1).toDouble(),
                  backgroundColor: AppColors.line,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(height: 14),
              if (r['my_vote_done'] == true)
                const Pill('Anda sudah mengonfirmasi', color: AppColors.success, icon: Icons.check_rounded)
              else
                BusyButton(label: 'Sudah teratasi', icon: Icons.task_alt_rounded, color: AppColors.success, onPressed: _vote),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 20),
      const SectionHeader('Penanganan instansi resmi',
          subtitle: 'Diisi manual. Menekan tombol telepon tidak mengubah status ini.'),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'unknown', label: Text('Belum')),
          ButtonSegment(value: 'dihubungi', label: Text('Dihubungi')),
          ButtonSegment(value: 'di_lokasi', label: Text('Di lokasi')),
        ],
        selected: {r['official_status'] as String},
        onSelectionChanged: active ? (s) => _setOfficial(s.first).catchError(showError) : null,
      ),
      const SizedBox(height: 20),
      if ((r['photo_urls'] as List).isNotEmpty) ...[
        const SectionHeader('Foto'),
        PhotoStrip(r['photo_urls'] as List),
      ],
    ];
  }
}

class _NeedCard extends StatelessWidget {
  const _NeedCard({required this.need});
  final Json need;

  @override
  Widget build(BuildContext context) {
    final quota = need['quota'] as int;
    final accepted = need['accepted'] as int;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(need['skill_name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              Text('$accepted/$quota', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: (accepted / quota).clamp(0, 1).toDouble(),
                backgroundColor: AppColors.line,
                color: accepted >= quota ? AppColors.success : AppColors.warning,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              NeedStatusPill(need['status'] as String?, exhausted: need['exhausted'] == true),
              if ((need['contacted'] as int) > 0 && need['status'] != 'selesai')
                Text('· ${need['contacted']} ditawari', style: const TextStyle(color: AppColors.inkMuted, fontSize: 13)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _VolunteerTile extends StatelessWidget {
  const _VolunteerTile({required this.v, this.onTap, this.onRelease});
  final Json v;
  final VoidCallback? onTap;
  final VoidCallback? onRelease;

  @override
  Widget build(BuildContext context) {
    final arrived = v['travel_status'] == 'sampai';
    final utama = v['role'] == 'utama';
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      leading: CircleAvatar(
        backgroundColor: arrived ? AppColors.successSoft : AppColors.primarySoft,
        child: Icon(arrived ? Icons.place_rounded : Icons.directions_run_rounded,
            color: arrived ? AppColors.success : AppColors.primary),
      ),
      title: Text(v['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(
        '${arrived ? 'Sudah di lokasi' : 'Menuju lokasi · ${km(v['distance_km'])}'}\n'
        '${v['skill']} · ${utama ? 'Utama' : 'Tambahan'} · ke-${v['order_number']}',
      ),
      isThreeLine: true,
      trailing: onRelease == null
          ? null
          : PopupMenuButton<String>(
              onSelected: (_) => onRelease!(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'release', child: Text('Lepas relawan'))],
            ),
    );
  }
}

/// Small live map: the incident and every volunteer on the way (FR-8.5).
class _LiveMap extends StatefulWidget {
  const _LiveMap({required this.report, required this.volunteers, required this.onTap});
  final Json report;
  final List<Json> volunteers;
  final VoidCallback onTap;

  @override
  State<_LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<_LiveMap> {
  final _map = MapController();
  LatLng? _lastSite;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final volunteers = widget.volunteers;
    final onTap = widget.onTap;
    final site = pointOf(report);
    // Nudge the camera instead of relying on a rebuild when the polled report
    // location changes -- flutter_map only fetches tiles after a camera
    // event, so a moved center that never triggers one would leave tiles
    // blank (see the dashboard's _MapPreview for the same fix).
    if (_lastSite != null && _lastSite != site) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _map.move(site, _map.camera.zoom);
        } catch (_) {
          // See kickTiles() in map_tiles.dart: can race with app teardown.
        }
      });
    }
    _lastSite = site;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 200,
        child: Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: site,
              initialZoom: 14.5,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              onTap: (_, _) => onTap(),
              // Force the first tile fetch -- on web, tiles otherwise sit
              // blank until the first camera event (flutter_map known issue).
              onMapReady: () => kickTiles(_map, site, 14.5, mounted: () => mounted),
            ),
            children: [
              osmTiles,
              MarkerLayer(markers: [
                for (final v in volunteers)
                  if (v['lat'] != null)
                    Marker(
                      point: pointOf(v),
                      width: 30,
                      height: 30,
                      child: MapDot(
                          icon: Icons.directions_run_rounded,
                          size: 30,
                          color: v['travel_status'] == 'sampai' ? AppColors.success : AppColors.info),
                    ),
                Marker(
                  point: site,
                  width: 42,
                  height: 42,
                  child: MapDot(icon: incidentIcon(report['incident_type'] as String?), color: AppColors.primary),
                ),
              ]),
            ],
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40), backgroundColor: AppColors.ink),
              onPressed: onTap,
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              label: const Text('Peta langsung'),
            ),
          ),
          const Positioned(left: 8, bottom: 8, child: OsmAttribution()),
        ]),
      ),
    );
  }
}
