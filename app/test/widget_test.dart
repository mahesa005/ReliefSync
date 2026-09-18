import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reliefsync/screens/report/extraction_confirm_screen.dart';
import 'package:reliefsync/services/api.dart';
import 'package:reliefsync/theme.dart';
import 'package:reliefsync/widgets/common.dart';
import 'package:reliefsync/widgets/incident_icon.dart';
import 'package:reliefsync/widgets/photo_viewer.dart';
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

  test('every backend incident type has its own icon', () {
    const codes = ['kebakaran', 'banjir', 'longsor', 'bangunan_roboh', 'kecelakaan', 'akses_terputus'];
    expect({for (final c in codes) incidentIcon(c)}.length, codes.length);
    expect(incidentIcon('lainnya'), Icons.emergency_rounded);
    expect(incidentIcon(null), Icons.emergency_rounded); // older payloads without the field
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
        'incident_type': 'banjir',
        'raw_text': 'Banjir setinggi dada, ada lansia terjebak.',
        'extraction_source': 'llm',
        'extraction_ms': 900,
        'extraction_note': null,
        'extraction': [
          {'field': 'title', 'label': 'Judul', 'value': 'Banjir di Gang Mawar', 'ai_value': 'Banjir di Gang Mawar',
           'evidence': null, 'confidence': 1.0},
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
      'incident_types': [
        {'code': 'kebakaran', 'label': 'Kebakaran', 'description': '...'},
        {'code': 'banjir', 'label': 'Banjir', 'description': '...'},
        {'code': 'lainnya', 'label': 'Darurat komunitas lainnya', 'description': '...'},
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
    expect(find.text('Banjir'), findsOneWidget); // incident type preselected from the report
  });

  testWidgets('tapping a photo opens a full-screen viewer you can swipe and close', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: const Scaffold(body: PhotoStrip(['/uploads/a.jpg', '/uploads/b.jpg', '/uploads/c.jpg'])),
    ));
    expect(find.byType(PhotoViewer), findsNothing);

    await tester.tap(find.byType(Image).at(1)); // open on the 2nd photo
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0)); // swipe to the next photo
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Tutup'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsNothing);
  });

  testWidgets('a single photo shows no page counter', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const PhotoViewer(urls: ['/uploads/a.jpg'])));
    await tester.pump();
    expect(find.textContaining('/ '), findsNothing);
    expect(find.byTooltip('Tutup'), findsOneWidget);
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
