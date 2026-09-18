import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';

/// OpenStreetMap tiles (no API key needed). Please respect the OSM tile usage
/// policy; for production switch to a paid/self-hosted tile provider.
final osmTiles = TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'id.steicon.reliefsync',
  maxZoom: 19,
);

class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(6)),
      child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 11, color: AppColors.inkMuted)),
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
