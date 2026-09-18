import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';

/// The backend's fixed skill catalog ([{skill_id, name}]), fetched once.
/// Matching is by skill_id, so volunteers can only pick from this list.
Future<List<Json>>? _catalogFuture;

Future<List<Json>> loadSkillCatalog() {
  final future = _catalogFuture ??= Api.instance.get('/skills').then((v) => (v as List).cast<Json>());
  // Don't cache a failure (e.g. offline): the next open should retry.
  future.catchError((_) {
    _catalogFuture = null;
    return <Json>[];
  });
  return future;
}

/// Skill chips (5.8): tap a catalog skill to add or remove it. On a selected
/// skill the shield toggles "bersertifikat" (certified evidence scores higher
/// than self-declared, context doc 4.2).
class SkillPicker extends StatefulWidget {
  const SkillPicker({super.key, required this.skills, required this.onChanged, this.catalog});
  final List<Json> skills; // [{skill_id, evidence}]
  final ValueChanged<List<Json>> onChanged;

  /// Injected catalog (tests); fetched from the API when null.
  final List<Json>? catalog;

  @override
  State<SkillPicker> createState() => _SkillPickerState();
}

class _SkillPickerState extends State<SkillPicker> {
  late Future<List<Json>> _catalog = _load();

  Future<List<Json>> _load() => widget.catalog != null ? Future.value(widget.catalog) : loadSkillCatalog();

  List<Json> get _skills => widget.skills;
  Json? _selected(int id) => _skills.where((x) => x['skill_id'] == id).firstOrNull;

  void _toggle(int id) => widget.onChanged(_selected(id) == null
      ? [..._skills, {'skill_id': id, 'evidence': 'self_declared'}]
      : _skills.where((x) => x['skill_id'] != id).toList());

  void _toggleCertified(int id) => widget.onChanged([
        for (final y in _skills)
          if (y['skill_id'] == id)
            {...y, 'evidence': y['evidence'] == 'certified' ? 'self_declared' : 'certified'}
          else
            y,
      ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Json>>(
      future: _catalog,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final catalog = snap.data ?? const <Json>[];
        if (catalog.isEmpty) {
          return Row(children: [
            const Expanded(
              child: Text('Daftar kemampuan gagal dimuat.', style: TextStyle(color: AppColors.inkMuted)),
            ),
            TextButton(onPressed: () => setState(() => _catalog = _load()), child: const Text('Coba lagi')),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in catalog) _chip(c['skill_id'] as int, c['name'] as String),
          ]),
          const SizedBox(height: 8),
          const Text('Ketuk kemampuan untuk memilih. Ketuk ikon perisai jika Anda punya sertifikatnya.',
              style: TextStyle(color: AppColors.inkMuted, fontSize: 12.5)),
        ]);
      },
    );
  }

  Widget _chip(int id, String name) {
    final sel = _selected(id);
    if (sel == null) {
      return ActionChip(avatar: const Icon(Icons.add_rounded, size: 18), label: Text(name), onPressed: () => _toggle(id));
    }
    final certified = sel['evidence'] == 'certified';
    return InputChip(
      selected: true,
      showCheckmark: false,
      selectedColor: AppColors.primarySoft,
      avatar: GestureDetector(
        onTap: () => _toggleCertified(id),
        child: Icon(
          certified ? Icons.verified_rounded : Icons.shield_outlined,
          size: 18,
          color: certified ? AppColors.success : AppColors.inkMuted,
        ),
      ),
      label: Text(name),
      onPressed: () => _toggleCertified(id),
      onDeleted: () => _toggle(id),
      deleteIcon: const Icon(Icons.close_rounded, size: 18),
    );
  }
}
