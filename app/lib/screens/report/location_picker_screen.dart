import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../services/location.dart';
import '../../theme.dart';
import '../../widgets/map_tiles.dart';

/// Manual location (FR-2.4): drag the map so the pin sits on the incident.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, this.initial});
  final LatLng? initial;

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late LatLng _center = widget.initial ?? LocationService.demoCenter;
  final _map = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pilih lokasi kejadian')),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _center,
            initialZoom: 17,
            onPositionChanged: (camera, _) => _center = camera.center,
            // Force the first tile fetch -- on web, tiles otherwise sit blank
            // until the first camera event (flutter_map known issue).
            onMapReady: () => _map.move(_center, 17),
          ),
          children: [osmTiles],
        ),
        const IgnorePointer(
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 44),
              child: Icon(Icons.location_on_rounded, size: 52, color: AppColors.primary),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          top: 12,
          child: Card(
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Geser peta hingga pin tepat di lokasi kejadian.',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ),
        const Positioned(left: 8, bottom: 90, child: OsmAttribution()),
        Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: SafeArea(
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context, _center),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Gunakan lokasi ini'),
            ),
          ),
        ),
      ]),
    );
  }
}
