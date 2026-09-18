import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reliefsync/screens/report/extraction_confirm_screen.dart';
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

  testWidgets('confirm screen renders the skill-catalog POST /reports response', (tester) async {
    final data = <String, dynamic>{
      'report': {
        'id': 'r1',
        'raw_text': 'Banjir setinggi dada, ada lansia terjebak.',
        'extraction_source': 'llm',
        'extraction_ms': 900,
        'extraction_note': null,
        'extraction': [
          {'field': 'title', 'label': 'Judul', 'value': 'Banjir', 'ai_value': 'Banjir', 'evidence': null, 'confidence': 1.0},
          {'field': 'description', 'label': 'Deskripsi', 'value': 'Banjir tinggi', 'ai_value': 'Banjir tinggi',
           'evidence': null, 'confidence': 1.0},
        ],
      },
      'proposed_needs': [
        {'skill_id': 12, 'quota': 3},
      ],
      'catalog': [
        {'skill_id': 1, 'name': 'P3K'},
        {'skill_id': 12, 'name': 'Berenang'},
      ],
    };
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ExtractionConfirmScreen(data: data)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Berenang'), findsOneWidget);
    expect(find.text('Disarankan AI'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // AI-proposed quota
  });

  testWidgets('skill picker adds and removes catalog skills by id', (tester) async {
    var skills = <Json>[];
    const catalog = [
      {'skill_id': 1, 'name': 'P3K'},
      {'skill_id': 11, 'name': 'Penggunaan APAR'},
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: SkillPicker(skills: skills, catalog: catalog, onChanged: (v) => setState(() => skills = v)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Penggunaan APAR'));
    await tester.pump();
    expect(skills.single['skill_id'], 11);
    expect(skills.single['evidence'], 'self_declared');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(skills, isEmpty);
  });
}
