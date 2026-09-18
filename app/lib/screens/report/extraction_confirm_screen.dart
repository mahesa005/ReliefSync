import 'package:flutter/material.dart';

import '../../services/api.dart';
import '../../services/incident_types.dart';
import '../../theme.dart';
import '../../widgets/agency_sheet.dart';
import '../../widgets/common.dart';
import 'report_status_screen.dart';

const _unknown = 'belum diketahui';

/// Reporter checks / corrects what the AI extracted (FR-3.2 - FR-3.5) and the
/// need categories + volunteer quotas mapped from it (FR-4.1 - FR-4.3).
/// Matching only starts after this confirmation.
class ExtractionConfirmScreen extends StatefulWidget {
  const ExtractionConfirmScreen({super.key, required this.data});
  final Json data; // {report, proposed_needs, catalog}

  @override
  State<ExtractionConfirmScreen> createState() => _ExtractionConfirmScreenState();
}

class _ExtractionConfirmScreenState extends State<ExtractionConfirmScreen> {
  late final Json _report = widget.data['report'] as Json;
  late final List<Json> _fields = (_report['extraction'] as List).cast<Json>();
  late final Map<String, TextEditingController> _controllers = {
    for (final f in _fields)
      f['field'] as String: TextEditingController(text: f['value'] == _unknown ? '' : f['value'] as String),
  };
  late final List<Json> _catalog = (widget.data['catalog'] as List).cast<Json>();
  late final List<Json> _proposed = (widget.data['proposed_needs'] as List).cast<Json>();
  late final Set<int> _suggested = {for (final n in _proposed) n['skill_id'] as int};
  late final Map<int, int> _selected = {for (final n in _proposed) n['skill_id'] as int: n['quota'] as int};
  late final List<Json> _incidentTypes = (widget.data['incident_types'] as List? ?? []).cast<Json>();
  late String? _incident = _incidentTypes.any((t) => t['code'] == _report['incident_type'])
      ? _report['incident_type'] as String
      : null;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty) {
      showMessage('Pilih minimal satu kebutuhan bantuan.', error: true);
      return;
    }
    final res = await Api.instance.post('/reports/${_report['id']}/confirm', {
      'fields': {for (final e in _controllers.entries) e.key: e.value.text.trim()},
      'needs': [for (final e in _selected.entries) {'skill_id': e.key, 'quota': e.value}],
      if (_incident != null) 'incident_type': _incident,
    }) as Json;
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => ReportStatusScreen(reportId: res['id'] as String)));
  }

  @override
  Widget build(BuildContext context) {
    final source = _report['extraction_source'] as String?;
    final ms = _report['extraction_ms'] as int?;
    final note = _report['extraction_note'] as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('Periksa laporan')),
      floatingActionButton: AgencyFab(reportId: _report['id'] as String),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
        children: [
          Text('Apakah ringkasan ini sesuai?', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text('Perbaiki jika ada yang keliru. Relawan baru dihubungi setelah Anda mengonfirmasi.',
              style: TextStyle(color: AppColors.inkMuted)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            switch (source) {
              'llm' => Pill('Diringkas AI${ms != null ? ' · ${(ms / 1000).toStringAsFixed(1)} dtk' : ''}',
                  color: AppColors.info, icon: Icons.auto_awesome_rounded),
              'form' => const Pill('Dari formulir', color: AppColors.info, icon: Icons.checklist_rounded),
              _ => const Pill('Ringkasan otomatis berbasis aturan', color: AppColors.warning, icon: Icons.rule_rounded),
            },
          ]),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(note, style: const TextStyle(color: AppColors.inkMuted, fontSize: 13)),
          ],
          if ((_report['raw_text'] as String).isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Teks asli Anda', style: TextStyle(color: AppColors.inkMuted, fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 4),
                Text(_report['raw_text'] as String, style: const TextStyle(fontSize: 15.5)),
              ]),
            ),
          ],
          const SizedBox(height: 18),
          if (_incidentTypes.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              initialValue: _incident,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Jenis kejadian',
                helperText: source == 'form' ? null : 'Ditentukan otomatis. Ubah jika keliru.',
              ),
              items: [
                for (final t in _incidentTypes)
                  DropdownMenuItem(value: t['code'] as String, child: Text(t['label'] as String)),
              ],
              onChanged: (v) => setState(() => _incident = v),
            ),
            if (_incident == kOtherIncident)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Judul di bawah dipakai sebagai nama kejadian.',
                    style: TextStyle(color: AppColors.inkMuted, fontSize: 13)),
              ),
            const SizedBox(height: 14),
          ],
          for (final f in _fields) ...[_FieldCard(field: f, controller: _controllers[f['field']]!), const SizedBox(height: 10)],
          const SizedBox(height: 14),
          SectionHeader('Bantuan yang dibutuhkan',
              subtitle: _suggested.isEmpty
                  ? 'Pilih skill relawan yang dibutuhkan dan jumlahnya.'
                  : 'Disarankan AI (bertanda). Atur skill dan jumlah relawan per kebutuhan.'),
          // AI suggestions first, then the rest of the catalog.
          for (final c in _catalog.where((c) => _suggested.contains(c['skill_id']))) _needTile(c),
          for (final c in _catalog.where((c) => !_suggested.contains(c['skill_id']))) _needTile(c),
          const SizedBox(height: 22),
          BusyButton(label: 'Konfirmasi & cari relawan', icon: Icons.person_search_rounded, onPressed: _confirm),
        ],
      ),
    );
  }

  Widget _needTile(Json c) {
    final id = c['skill_id'] as int;
    final on = _selected.containsKey(id);
    final quota = _selected[id] ?? 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: on ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => on ? _selected.remove(id) : _selected[id] = quota),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: on ? AppColors.primary.withValues(alpha: 0.4) : AppColors.line),
            ),
            child: Row(children: [
              Checkbox(value: on, onChanged: (_) => setState(() => on ? _selected.remove(id) : _selected[id] = quota)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  if (_suggested.contains(id))
                    const Text('Disarankan AI', style: TextStyle(color: AppColors.info, fontSize: 13, fontWeight: FontWeight.w700)),
                ]),
              ),
              if (on) ...[
                IconButton(
                  tooltip: 'Kurangi',
                  onPressed: quota > 1 ? () => setState(() => _selected[id] = quota - 1) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text('$quota', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                IconButton(
                  tooltip: 'Tambah',
                  onPressed: quota < 50 ? () => setState(() => _selected[id] = quota + 1) : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({required this.field, required this.controller});
  final Json field;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final evidence = field['evidence'] as String?;
    final confidence = (field['confidence'] as num?)?.toDouble() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(field['label'] as String, style: const TextStyle(fontWeight: FontWeight.w800))),
            if (evidence != null)
              Text('Keyakinan ${(confidence * 100).round()}%',
                  style: const TextStyle(color: AppColors.inkMuted, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            minLines: 1,
            maxLines: field['field'] == 'description' ? 8 : 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Belum diketahui', isDense: true),
          ),
          if (evidence != null) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.format_quote_rounded, size: 18, color: AppColors.inkMuted),
              const SizedBox(width: 4),
              Expanded(
                child: Text('Bukti dari teks: "$evidence"',
                    style: const TextStyle(color: AppColors.inkMuted, fontStyle: FontStyle.italic, fontSize: 13.5)),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
