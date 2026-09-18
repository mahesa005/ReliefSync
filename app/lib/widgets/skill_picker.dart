import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';

/// Skills used by the need catalog (backend `need_catalog`). SkillMatch is an
/// exact match, so suggested chips use exactly these names.
const kSuggestedSkills = [
  'Pemadaman Api',
  'Evakuasi',
  'P3K',
  'Logistik',
  'Pengaturan Lalu Lintas',
  'Dukungan Psikososial',
];

/// Skill chips (5.8): tap a suggestion or type one and press + to add; tap a
/// selected chip to remove it. The shield toggles "bersertifikat" (certified
/// evidence scores higher than self-declared, context doc 4.2).
class SkillPicker extends StatefulWidget {
  const SkillPicker({super.key, required this.skills, required this.onChanged});
  final List<Json> skills; // [{skill, evidence}]
  final ValueChanged<List<Json>> onChanged;

  @override
  State<SkillPicker> createState() => _SkillPickerState();
}

class _SkillPickerState extends State<SkillPicker> {
  final _custom = TextEditingController();

  List<Json> get _skills => widget.skills;
  bool _has(String s) => _skills.any((x) => (x['skill'] as String).toLowerCase() == s.toLowerCase());

  void _add(String s) {
    s = s.trim();
    if (s.isEmpty || _has(s)) return;
    widget.onChanged([..._skills, {'skill': s, 'evidence': 'self_declared'}]);
    _custom.clear();
  }

  void _remove(String s) => widget.onChanged(_skills.where((x) => x['skill'] != s).toList());

  void _toggleCertified(Json x) => widget.onChanged([
        for (final y in _skills)
          if (y == x)
            {...y, 'evidence': y['evidence'] == 'certified' ? 'self_declared' : 'certified'}
          else
            y,
      ]);

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = kSuggestedSkills.where((s) => !_has(s)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_skills.isEmpty)
        const Text('Belum ada kemampuan dipilih.', style: TextStyle(color: AppColors.inkMuted))
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final x in _skills)
            InputChip(
              selected: true,
              showCheckmark: false,
              selectedColor: AppColors.primarySoft,
              avatar: GestureDetector(
                onTap: () => _toggleCertified(x),
                child: Icon(
                  x['evidence'] == 'certified' ? Icons.verified_rounded : Icons.shield_outlined,
                  size: 18,
                  color: x['evidence'] == 'certified' ? AppColors.success : AppColors.inkMuted,
                ),
              ),
              label: Text(x['skill'] as String),
              onPressed: () => _toggleCertified(x),
              onDeleted: () => _remove(x['skill'] as String),
              deleteIcon: const Icon(Icons.close_rounded, size: 18),
            ),
        ]),
      const SizedBox(height: 6),
      const Text('Ketuk ikon perisai jika Anda punya sertifikat untuk kemampuan tersebut.',
          style: TextStyle(color: AppColors.inkMuted, fontSize: 12.5)),
      const SizedBox(height: 14),
      if (suggestions.isNotEmpty) ...[
        const Text('Saran', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in suggestions)
            ActionChip(avatar: const Icon(Icons.add_rounded, size: 18), label: Text(s), onPressed: () => _add(s)),
        ]),
        const SizedBox(height: 12),
      ],
      Row(children: [
        Expanded(
          child: TextField(
            controller: _custom,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Kemampuan lain', isDense: true),
            onSubmitted: _add,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(onPressed: () => _add(_custom.text), icon: const Icon(Icons.add_rounded)),
      ]),
    ]);
  }
}
