import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reliefsync/services/api.dart';
import 'package:reliefsync/theme.dart';
import 'package:reliefsync/widgets/common.dart';
import 'package:reliefsync/widgets/skill_picker.dart';

void main() {
  test('theme uses Nunito Sans', () {
    expect(buildTheme().textTheme.bodyMedium?.fontFamily, kFontFamily);
  });

  test('distance and time formatting', () {
    expect(km(0.35), '350 m');
    expect(km(2.44), '2.4 km');
    expect(timeAgo(DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String()), '5 menit lalu');
  });

  testWidgets('trust badge shows tier label, never a number', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: const Scaffold(body: TrustBadge({'tier': 'baik', 'label': 'Riwayat baik'})),
    ));
    expect(find.text('Riwayat baik'), findsOneWidget);
  });

  testWidgets('skill picker adds and removes chips', (tester) async {
    var skills = <Json>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: SkillPicker(skills: skills, onChanged: (v) => setState(() => skills = v)),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Evakuasi'));
    await tester.pump();
    expect(skills.single['skill'], 'Evakuasi');
    expect(skills.single['evidence'], 'self_declared');
  });
}
