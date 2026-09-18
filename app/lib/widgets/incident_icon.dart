import 'package:flutter/material.dart';

/// Icon per incident type code (backend `INCIDENT_TYPES`); anything else,
/// including "lainnya", gets the generic emergency icon.
IconData incidentIcon(String? type) => switch (type) {
      'kebakaran' => Icons.local_fire_department_rounded,
      'banjir' => Icons.flood_rounded,
      'longsor' => Icons.landslide_rounded,
      'bangunan_roboh' => Icons.domain_disabled_rounded,
      'kecelakaan' => Icons.car_crash_rounded,
      'akses_terputus' => Icons.remove_road_rounded,
      _ => Icons.emergency_rounded,
    };
