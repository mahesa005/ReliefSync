import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/api.dart';
import '../../services/location.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/map_tiles.dart';
import '../../widgets/report_peek_sheet.dart';

/// Full map (5.4): scroll / pinch-zoom, an icon per active incident; tap for
/// details, "saya melihat kejadian ini", agency contact and (for volunteers)
/// participation. With [trackReportId] it also shows that report's volunteers
/// moving live (FR-8.5).
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.focus, this.trackReportId});
  final LatLng? focus;
  final String? trackReportId;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  List<Json> _reports = [];
  List<Json> _volunteers = [];
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
      final reports = (await Api.instance.get('/reports/active') as List).cast<Json>();
      List<Json> volunteers = [];
      if (widget.trackReportId != null) {
        final r = await Api.instance.get('/reports/${widget.trackReportId}') as Json;
        volunteers = (r['volunteers'] as List? ?? []).cast<Json>();
        if (!reports.any((x) => x['id'] == r['id'])) reports.add(r);
      }
      if (mounted) {
        setState(() {
          _reports = reports;
          _volunteers = volunteers;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<LocationService>().current;
    final center = widget.focus ?? me ?? LocationService.demoCenter;
    // Deliberately NOT re-centering on every `center` change here: this map
    // is meant to be freely pannable/zoomable (unlike the dashboard preview),
    // so auto-recentering on each GPS tick would fight the user's manual pan
    // and make the map feel frozen. Recenter is user-triggered only, via the
    // "my location" FAB below.
    return Scaffold(
      appBar: AppBar(title: Text(widget.trackReportId != null ? 'Pantau relawan' : 'Peta kejadian')),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            // Force the first tile fetch -- on web, tiles otherwise sit blank
            // until the first camera event (flutter_map known issue). Deferred
            // a frame because on web the viewport can still be zero-sized
            // when onMapReady fires, which makes an immediate move() a no-op.
            onMapReady: () => WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _map.move(center, 15);
            }),
          ),
          children: [
            osmTiles,
            MarkerLayer(markers: [
              if (me != null)
                Marker(
                  point: me,
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.info,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                    ),
                  ),
                ),
              for (final v in _volunteers)
                if (v['lat'] != null)
                  Marker(
                    point: pointOf(v),
                    width: 120,
                    height: 64,
                    child: _VolunteerMarker(v: v),
                  ),
              for (final r in _reports)
                Marker(
                  point: pointOf(r),
                  width: 46,
                  height: 46,
                  child: GestureDetector(
                    onTap: () => showReportPeek(r['id'] as String),
                    child: MapDot(
                      icon: Icons.local_fire_department_rounded,
                      color: r['is_mine'] == true || r['is_reporter'] == true ? AppColors.primaryDark : AppColors.primary,
                      size: 46,
                      highlight: r['id'] == widget.trackReportId,
                    ),
                  ),
                ),
            ]),
          ],
        ),
        const Positioned(left: 8, bottom: 8, child: OsmAttribution()),
        Positioned(
          left: 16,
          top: 12,
          child: Pill('${_reports.length} kejadian aktif', color: AppColors.ink, background: Colors.white,
              icon: Icons.local_fire_department_rounded),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        heroTag: 'locate',
        tooltip: 'Lokasi saya',
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        onPressed: () async {
          final loc = await context.read<LocationService>().refresh();
          if (loc != null) _map.move(loc, 16);
        },
        child: const Icon(Icons.my_location_rounded),
      ),
    );
  }
}

class _VolunteerMarker extends StatelessWidget {
  const _VolunteerMarker({required this.v});
  final Json v;

  @override
  Widget build(BuildContext context) {
    final arrived = v['travel_status'] == 'sampai';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
        child: Text((v['name'] as String).split(' ').first,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
      ),
      const SizedBox(height: 2),
      MapDot(
        icon: Icons.directions_run_rounded,
        size: 34,
        color: arrived ? AppColors.success : AppColors.info,
      ),
    ]);
  }
}
