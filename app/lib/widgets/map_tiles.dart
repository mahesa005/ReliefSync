import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';

/// OpenStreetMap data served via CARTO's free basemap CDN (no API key
/// needed). The OSM Foundation's own tile.openstreetmap.org is meant for
/// light/testing use only and throttles app-scale traffic, which showed up
/// as intermittently blank tiles; CARTO's CDN is built for exactly this.
/// https://github.com/CartoDB/basemap-styles
final osmTiles = TileLayer(
  urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
  subdomains: const ['a', 'b', 'c', 'd'],
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
