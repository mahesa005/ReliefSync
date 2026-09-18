import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';

/// OpenStreetMap data served via CARTO's basemap CDN. The OSM Foundation's
/// own tile.openstreetmap.org is meant for light/testing use only and
/// throttles app-scale traffic, which showed up as intermittently blank
/// tiles; CARTO's CDN is built for exactly this.
///
/// The API key is never hardcoded: pass it at build/run time with
/// `--dart-define=CARTO_API_KEY=...` (see `dart_define.example.json` for the
/// `--dart-define-from-file` equivalent). Without a key the request is sent
/// unauthenticated, which CARTO still serves at a lower rate limit.
const _cartoApiKey = String.fromEnvironment('CARTO_API_KEY');

///
/// This is a getter, not a `final` value, on purpose: TileLayer keeps
/// internal per-instance state (its tile cache/manager), so sharing one
/// object across multiple FlutterMap widgets let whichever map mounted
/// first "claim" that state, leaving every other map's TileLayer wired up
/// but never actually requesting tiles. Each call here returns a fresh
/// instance so every map gets its own.
TileLayer get osmTiles => TileLayer(
  urlTemplate: 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'
      '${_cartoApiKey.isEmpty ? '' : '?key=$_cartoApiKey'}',
  userAgentPackageName: 'id.steicon.reliefsync',
  maxZoom: 20,
);

class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(6)),
      child: const Text('© OpenStreetMap · © CARTO', style: TextStyle(fontSize: 11, color: AppColors.inkMuted)),
    );
  }
}

/// Round marker used for incidents / volunteers.
class MapDot extends StatelessWidget {
  const MapDot({super.key, required this.icon, required this.color, this.size = 40, this.highlight = false});
  final IconData icon;
  final Color color;
  final double size;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: highlight ? 4 : 3),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: highlight ? 16 : 8)],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.55),
    );
  }
}

/// LatLng from a JSON object with `lat` / `lng` (ints or doubles).
LatLng pointOf(Map j) => LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble());

/// Nudges the map camera a few times over ~1s after `onMapReady` fires.
///
/// flutter_map only fetches tiles in response to a camera event, and on web
/// the map's viewport can still be reporting a zero size for several frames
/// after onMapReady (CanvasKit/layout not settled yet), so a single
/// `move()` right away can silently compute an empty viewport and never
/// issue a single tile request. Retrying a few times over the following
/// second is a cheap way to land on a frame where the size is real.
void kickTiles(MapController controller, LatLng center, double zoom, {required bool Function() mounted}) {
  for (final delay in const [Duration.zero, Duration(milliseconds: 150), Duration(milliseconds: 400), Duration(milliseconds: 900)]) {
    Future.delayed(delay, () {
      if (!mounted()) return;
      try {
        controller.move(center, zoom);
      } catch (_) {
        // A late timer can outlive the app instance (e.g. a Flutter Web hot
        // restart tears down the engine view while this is still pending) --
        // that's a dev-time artifact, not a real failure, so swallow it.
      }
    });
  }
}
