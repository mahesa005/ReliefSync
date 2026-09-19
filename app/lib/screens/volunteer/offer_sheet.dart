import 'package:flutter/material.dart';

import '../../app_nav.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'task_screen.dart';

/// Opens a (standard) request as a bottom sheet with Accept / Deny (5.9).
Future<void> openOffer(String offerId) async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  Json offer;
  try {
    offer = await Api.instance.get('/offers/$offerId') as Json;
  } catch (e) {
    showError(e);
    return;
  }
  if (!ctx.mounted) return;
  await showModalBottomSheet(
    context: ctx,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OfferDetails(offer: offer),
          const SizedBox(height: 18),
          OfferActions(offer: offer, onDone: () => Navigator.pop(context)),
        ]),
      ),
    ),
  );
}

Future<void> acceptOffer(Json offer) async {
  final task = await Api.instance.post('/offers/${offer['offer_id']}/accept') as Json;
  showMessage(task['role'] == 'utama'
      ? 'Anda relawan ke-${task['order_number']} (Bantuan Utama). Lokasi Anda dibagikan ke pelapor.'
      : 'Anda bergabung sebagai Bantuan Tambahan. Lokasi Anda dibagikan ke pelapor.');
  pushScreen(TaskScreen(assignmentId: task['id'] as String));
}

Future<void> rejectOffer(Json offer) async {
  await Api.instance.post('/offers/${offer['offer_id']}/reject');
  showMessage('Permintaan ditolak. Masih tersimpan di daftar permintaan jika Anda berubah pikiran.');
}

/// Description of an offered incident. Shows which of the volunteer's skills
/// matched and the reporter's trust tier (FR-9.3) -- no reporter identity.
class OfferDetails extends StatelessWidget {
  const OfferDetails({super.key, required this.offer, this.onDark = false});
  final Json offer;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final need = offer['need'] as Json;
    final fg = onDark ? Colors.white : AppColors.ink;
    final muted = onDark ? Colors.white70 : AppColors.inkMuted;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(offer['incident_label'] as String,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: fg, height: 1.15)),
      const SizedBox(height: 6),
      Text('${km(offer['distance_km'])} dari Anda · dilaporkan ${timeAgo(offer['received_at'])}',
          style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
      const SizedBox(height: 14),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: onDark ? Colors.white.withValues(alpha: 0.12) : AppColors.primarySoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Skill Anda yang dibutuhkan', style: TextStyle(color: muted, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.bolt_rounded, color: onDark ? Colors.white : AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${offer['matched_skill']} · ${need['label']}',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: fg)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('${need['accepted']} dari ${need['quota']} relawan sudah bersedia',
              style: TextStyle(color: muted, fontWeight: FontWeight.w600)),
        ]),
      ),
      const SizedBox(height: 14),
      if ((offer['raw_text'] as String).isNotEmpty)
        Text('"${offer['raw_text']}"', style: TextStyle(fontSize: 16, color: fg, height: 1.45)),
      if (offer['address_text'] != null) ...[
        const SizedBox(height: 8),
        Text(offer['address_text'] as String, style: TextStyle(color: muted)),
      ],
      const SizedBox(height: 12),
      PhotoStrip(offer['photo_urls'] as List),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Pelapor:', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
        TrustBadge(offer['reporter_trust'] as Json?),
        VerifierTrustBadge(offer['reporter_verifier_trust'] as Json?),
        if (offer['contact_phone_masked'] != null)
          Pill(offer['contact_phone_masked'] as String, icon: Icons.phone_rounded,
              color: onDark ? Colors.white : AppColors.inkMuted),
      ]),
    ]);
  }
}

class OfferActions extends StatelessWidget {
  const OfferActions({super.key, required this.offer, required this.onDone, this.onDark = false});
  final Json offer;
  final VoidCallback onDone;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final rejected = offer['status'] == 'rejected';
    return Row(children: [
      if (!rejected) ...[
        Expanded(
          child: OutlinedButton(
            style: onDark
                ? OutlinedButton.styleFrom(
                    foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70, width: 1.5))
                : null,
            onPressed: () async {
              try {
                await rejectOffer(offer);
                onDone();
              } catch (e) {
                showError(e);
              }
            },
            child: const Text('Tolak'),
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        flex: 2,
        child: BusyButton(
          label: rejected ? 'Terima sekarang' : 'Terima tugas',
          icon: Icons.check_rounded,
          color: onDark ? AppColors.ink : null,
          onPressed: () async {
            onDone();
            await acceptOffer(offer);
          },
        ),
      ),
    ]);
  }
}
