import 'package:flutter/material.dart';

import '../app_nav.dart';
import '../services/api.dart';
import '../theme.dart';
import 'common.dart';

/// Periodic "Apakah bencana ini sudah teratasi?" (5.11). "Ya" is the same vote as
/// the "Sudah teratasi" button on the task page; "Belum" keeps the person active
/// in the quorum (not AFK).
Future<void> showResolvedPrompt(String reportId, String? address) async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  final answer = await showDialog<bool>(
    context: ctx,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.how_to_vote_rounded, color: AppColors.primary, size: 36),
      title: const Text('Apakah bencana ini sudah teratasi?', textAlign: TextAlign.center),
      content: Text(
        '${address?.isNotEmpty == true ? '$address\n\n' : ''}Status "Selesai" butuh konfirmasi dari beberapa orang '
        'yang terlibat. Jika tidak menjawab, Anda dianggap tidak aktif untuk konfirmasi ini.',
        textAlign: TextAlign.center,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Belum')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ya, sudah teratasi')),
      ],
    ),
  );
  if (answer == null) return;
  try {
    final r = await Api.instance.post('/reports/$reportId/vote', {'done': answer}) as Json;
    if (answer) {
      showMessage(r['status'] == 'resolved'
          ? 'Kejadian dinyatakan selesai. Terima kasih!'
          : 'Konfirmasi tercatat (${r['quorum']?['votes'] ?? '-'}/${r['quorum']?['required'] ?? '-'}).');
    }
  } catch (e) {
    showError(e);
  }
}

/// FR-7.3: after resolution, did the field match the original report? Feeds the
/// reporter's trust score.
Future<void> showAccuracyPrompt(String reportId, String? rawText) async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  final answer = await showDialog<bool>(
    context: ctx,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.fact_check_rounded, color: AppColors.info, size: 36),
      title: const Text('Sesuai dengan laporan?', textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Kejadian sudah selesai. Apakah kondisi di lapangan sesuai dengan laporan awal?',
            textAlign: TextAlign.center),
        if (rawText != null && rawText.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12)),
            child: Text('"$rawText"', style: const TextStyle(fontStyle: FontStyle.italic)),
          ),
        ],
      ]),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Tidak sesuai')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sesuai')),
      ],
    ),
  );
  if (answer == null) return;
  try {
    await Api.instance.post('/reports/$reportId/accuracy', {'matches': answer});
    showMessage('Terima kasih atas penilaiannya.');
  } catch (e) {
    showError(e);
  }
}
