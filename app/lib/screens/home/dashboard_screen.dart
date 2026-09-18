import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/alerts.dart';
import '../../services/api.dart';
import '../../services/location.dart';
import '../../services/push.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/report_peek_sheet.dart';
import '../map/map_screen.dart';
import '../profile/profile_screen.dart';
import '../report/create_report_screen.dart';
import '../report/report_status_screen.dart';
import '../volunteer/offer_sheet.dart';
import '../volunteer/task_screen.dart';
import 'notifications_screen.dart';

/// Dashboard (5.2). The volunteer dashboard is a superset of the reporter one:
/// same widgets plus "Permintaan relawan" and active tasks.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _timer;
  int _seenVersion = -1;

  List<Json> _active = [];
  List<Json> _mine = [];
  List<Json> _requests = [];
  List<Json> _tasks = [];
  Json? _nearby;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<LocationService>().startTracking();
      if (!mounted) return;
      final isVolunteer = context.read<Session>().isVolunteer;
      context.read<AlertCenter>().start(isVolunteer: isVolunteer);
      Push.register(isVolunteer: isVolunteer);
      _load();
    });
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({double? radius}) async {
    final session = context.read<Session>();
    final loc = context.read<LocationService>().current;
    final api = Api.instance;
    try {
      final results = await Future.wait([
        api.get('/reports/active'),
        api.get('/reports/mine'),
        api.get('/reports/nearby', query: {
          'lat': loc?.latitude,
          'lng': loc?.longitude,
          'radius_km': radius,
        }),
        if (session.isVolunteer) api.get('/volunteer/requests'),
        if (session.isVolunteer) api.get('/volunteer/tasks'),
      ]);
      if (!mounted) return;
      setState(() {
        _active = (results[0] as List).cast<Json>();
        _mine = (results[1] as List).cast<Json>().where((r) => r['status'] == 'active').toList();
        _nearby = results[2] as Json;
        _requests = session.isVolunteer ? (results[3] as List).cast<Json>() : [];
        _tasks = session.isVolunteer
            ? (results[4] as List).cast<Json>().where((t) => t['status'] == 'aktif').toList()
            : [];
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final alerts = context.watch<AlertCenter>();
    if (alerts.version != _seenVersion) {
      _seenVersion = alerts.version;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const LogoFull(height: 30),
        actions: [
          IconButton(
            tooltip: 'Notifikasi',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen())),
            icon: Badge(
              isLabelVisible: alerts.unread > 0,
              label: Text('${alerts.unread}'),
              child: const Icon(Icons.notifications_none_rounded),
            ),
          ),
          IconButton(
            tooltip: 'Profil',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Row(children: [
              Expanded(
                child: Text('Halo, ${session.firstName}',
                    style: Theme.of(context).textTheme.headlineSmall, overflow: TextOverflow.ellipsis),
              ),
              if (session.isVolunteer)
                Pill(session.isActiveVolunteer ? 'Relawan aktif' : 'Relawan nonaktif',
                    color: session.isActiveVolunteer ? AppColors.success : AppColors.inkMuted,
                    icon: Icons.volunteer_activism_rounded),
            ]),
            const SizedBox(height: 14),
            _ReportCta(onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateReportScreen()));
              _load();
            }),
            const SizedBox(height: 14),
            _MapPreview(reports: _active),
            if (session.isVolunteer) ...[
              const SizedBox(height: 22),
              _requestsWidget(),
            ],
            if (_tasks.isNotEmpty) ...[
              const SizedBox(height: 22),
              const SectionHeader('Tugas aktif saya'),
              for (final t in _tasks) _taskTile(t),
            ],
            if (_mine.isNotEmpty) ...[
              const SizedBox(height: 22),
              const SectionHeader('Laporan saya'),
              for (final r in _mine) _myReportTile(r),
            ],
            const SizedBox(height: 22),
            _nearbyWidget(),
          ],
        ),
      ),
    );
  }

  Widget _requestsWidget() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader('Permintaan relawan',
          subtitle: 'Kejadian di sekitar Anda yang membutuhkan kemampuan Anda.'),
      if (_requests.isEmpty)
        const Card(child: EmptyHint(icon: Icons.inbox_outlined, text: 'Belum ada permintaan. Kami akan membunyikan alarm jika dibutuhkan.'))
      else
        for (final r in _requests)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              color: r['alarm_active'] == true ? AppColors.primarySoft : null,
              child: ListTile(
                onTap: () => openOffer(r['offer_id'] as String),
                contentPadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
                leading: CircleAvatar(
                  backgroundColor: r['alarm_active'] == true ? AppColors.primary : AppColors.background,
                  child: Icon(r['alarm_active'] == true ? Icons.notifications_active_rounded : Icons.volunteer_activism_outlined,
                      color: r['alarm_active'] == true ? Colors.white : AppColors.ink),
                ),
                title: Text('${r['incident_label']} · ${km(r['distance_km'])}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                  '${r['matched_skill']} · ${(r['need'] as Json)['accepted']}/${(r['need'] as Json)['quota']} relawan · '
                  '${r['status'] == 'rejected' ? 'Anda tolak, masih bisa diterima' : timeAgo(r['notified_at'])}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ),
          ),
    ]);
  }

  Widget _taskTile(Json t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => TaskScreen(assignmentId: t['id'] as String))),
          leading: CircleAvatar(
            backgroundColor: AppColors.primarySoft,
            child: Text('#${t['order_number']}',
                style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.primary)),
          ),
          title: Text('${t['incident_label']}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('${t['skill']} · ${t['travel_status'] == 'sampai' ? 'Sudah di lokasi' : 'Menuju lokasi'}'),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }

  Widget _myReportTile(Json r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => ReportStatusScreen(reportId: r['id'] as String))),
          leading: const CircleAvatar(
            backgroundColor: AppColors.primarySoft,
            child: Icon(Icons.monitor_heart_outlined, color: AppColors.primary),
          ),
          title: Text('${r['incident_label']}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('${r['accepted_total']}/${r['needs_total']} relawan bersedia · ${timeAgo(r['received_at'])}'),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }

  Widget _nearbyWidget() {
    final nearby = _nearby;
    final radius = (nearby?['radius_km'] as num?)?.toDouble() ?? 3;
    final notified = (nearby?['notified'] as List?)?.cast<Json>() ?? [];
    final general = (nearby?['general'] as List?)?.cast<Json>() ?? [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('Laporan sekitar', subtitle: 'Ketuk untuk konfirmasi "saya melihat kejadian ini".'),
      Wrap(spacing: 8, children: [
        for (final r in const [1.0, 3.0, 5.0])
          ChoiceChip(
            label: Text('${r.toInt()} km'),
            selected: radius == r,
            onSelected: (_) => _load(radius: r),
          ),
      ]),
      const SizedBox(height: 12),
      Text('Dalam radius ${radius.toInt()} km Anda', style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      if (notified.isEmpty)
        const Card(child: EmptyHint(icon: Icons.check_circle_outline_rounded, text: 'Tidak ada laporan di radius ini.'))
      else
        for (final r in notified) _nearbyTile(r),
      const SizedBox(height: 14),
      const Text('Laporan lain di sekitar', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      if (general.isEmpty)
        const Card(child: EmptyHint(icon: Icons.public_rounded, text: 'Tidak ada laporan aktif lainnya.'))
      else
        for (final r in general) _nearbyTile(r),
    ]);
  }

  Widget _nearbyTile(Json r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          onTap: () => showReportPeek(r['id'] as String).then((_) => _load()),
          leading: const CircleAvatar(
            backgroundColor: AppColors.primarySoft,
            child: Icon(Icons.local_fire_department_rounded, color: AppColors.primary),
          ),
          title: Text('${r['incident_label']} · ${km(r['distance_km'])}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('${r['sightings']} orang melihat · ${timeAgo(r['received_at'])}'),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }
}

class _ReportCta extends StatelessWidget {
  const _ReportCta({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 32),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Laporkan kejadian',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
                SizedBox(height: 2),
                Text('Ceritakan apa yang terjadi, kami carikan relawan terdekat.',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Icon(Icons.arrow_forward_rounded, color: Colors.white),
          ]),
        ),
      ),
    );
  }
}

class _MapPreview extends StatefulWidget {
  const _MapPreview({required this.reports});
  final List<Json> reports;

  @override
  State<_MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<_MapPreview> {
  final _controller = MapController();
  LatLng? _lastCenter;

  @override
  Widget build(BuildContext context) {
    final me = context.watch<LocationService>().current;
    final center = me ?? LocationService.demoCenter;
    // Nudge the camera instead of rebuilding the widget when location updates
    // arrive -- flutter_map only fetches tiles after a camera event, so
    // recreating the widget on every GPS tick (its old ValueKey did this)
    // meant tiles never got a chance to load (see FAQ: docs.fleaflet.dev).
    if (_lastCenter != null && _lastCenter != center) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _controller.move(center, _controller.camera.zoom);
        } catch (_) {
          // See kickTiles() in map_tiles.dart: can race with app teardown.
        }
      });
    }
    _lastCenter = center;
    void open() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapScreen()));
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 180,
        child: Stack(children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 13.5,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              onTap: (_, _) => open(),
              // Force the first tile fetch -- on web, tiles otherwise sit
              // blank until the first camera event (flutter_map known issue).
              onMapReady: () => kickTiles(_controller, center, 13.5, mounted: () => mounted),
            ),
            children: [
              osmTiles,
              MarkerLayer(markers: [
                if (me != null)
                  Marker(
                    point: me,
                    width: 18,
                    height: 18,
                    child: Container(
                      decoration: BoxDecoration(
                          color: AppColors.info, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                    ),
                  ),
                for (final r in widget.reports)
                  Marker(
                    point: pointOf(r),
                    width: 32,
                    height: 32,
                    child: const MapDot(icon: Icons.local_fire_department_rounded, color: AppColors.primary, size: 32),
                  ),
              ]),
            ],
          ),
          Positioned(
            left: 10,
            top: 10,
            child: Pill('${widget.reports.length} kejadian aktif', color: AppColors.ink, background: Colors.white),
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40), backgroundColor: AppColors.ink),
              onPressed: open,
              icon: const Icon(Icons.map_rounded, size: 18),
              label: const Text('Buka peta'),
            ),
          ),
          const Positioned(left: 8, bottom: 8, child: OsmAttribution()),
        ]),
      ),
    );
  }
}
