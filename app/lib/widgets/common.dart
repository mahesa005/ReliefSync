import 'package:flutter/material.dart';

import '../app_nav.dart';
import '../services/api.dart';
import '../theme.dart';
import 'photo_viewer.dart';

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------
DateTime? parseTime(dynamic iso) => iso is String ? DateTime.tryParse(iso)?.toLocal() : null;

/// "baru saja", "5 menit lalu", "2 jam lalu", "3 hari lalu".
String timeAgo(dynamic iso) {
  final t = parseTime(iso);
  if (t == null) return '-';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'baru saja';
  if (d.inMinutes < 60) return '${d.inMinutes} menit lalu';
  if (d.inHours < 24) return '${d.inHours} jam lalu';
  return '${d.inDays} hari lalu';
}

/// Duration since a timestamp, e.g. "12 mnt" / "1 j 5 mnt".
String durationSince(dynamic iso) {
  final t = parseTime(iso);
  if (t == null) return '-';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '< 1 mnt';
  if (d.inHours < 1) return '${d.inMinutes} mnt';
  return '${d.inHours} j ${d.inMinutes % 60} mnt';
}

String km(dynamic value) {
  if (value is! num) return '-';
  if (value < 1) return '${(value * 1000).round()} m';
  return '${value.toStringAsFixed(1)} km';
}

// ---------------------------------------------------------------------------
// Feedback helpers
// ---------------------------------------------------------------------------
void showMessage(String text, {bool error = false, SnackBarAction? action}) {
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? AppColors.primaryDark : AppColors.ink,
      action: action,
      duration: Duration(seconds: action != null ? 6 : 3),
    ));
}

void showError(Object e) => showMessage(e is ApiException ? e.message : 'Terjadi kesalahan: $e', error: true);

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/images/logo_icon.png', height: size, filterQuality: FilterQuality.medium);
}

class LogoFull extends StatelessWidget {
  const LogoFull({super.key, this.height = 44});
  final double height;

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/images/logo_full.png', height: height, filterQuality: FilterQuality.medium);
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color = AppColors.inkMuted, this.background, this.icon});
  final String label;
  final Color color;
  final Color? background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
      ]),
    );
  }
}

/// Reporter credibility as one of 3 tiers, never a raw number (FR-9.2).
class TrustBadge extends StatelessWidget {
  const TrustBadge(this.trust, {super.key});
  final Json? trust;

  @override
  Widget build(BuildContext context) {
    final tier = trust?['tier'] ?? 'baru';
    final label = (trust?['label'] ?? 'Akun baru') as String;
    return switch (tier) {
      'baik' => Pill(label, color: AppColors.success, icon: Icons.verified_rounded),
      'rendah' => Pill(label, color: AppColors.warning, icon: Icons.error_outline_rounded),
      _ => Pill(label, color: AppColors.info, icon: Icons.fiber_new_rounded),
    };
  }
}

/// Need status (FR-8.1).
class NeedStatusPill extends StatelessWidget {
  const NeedStatusPill(this.status, {super.key, this.exhausted = false});
  final String? status;
  final bool exhausted;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      'penuh' => const Pill('Tertangani penuh', color: AppColors.success),
      'sebagian' => Pill(exhausted ? 'Sebagian (kandidat habis)' : 'Sebagian terpenuhi', color: AppColors.warning),
      'selesai' => const Pill('Selesai', color: AppColors.success),
      _ => Pill(exhausted ? 'Belum ada (tak ada kandidat)' : 'Belum ada penanggung jawab',
          color: AppColors.primary),
    };
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            if (subtitle != null)
              Text(subtitle!, style: const TextStyle(color: AppColors.inkMuted, fontSize: 13.5)),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Row(children: [
        Icon(icon, color: AppColors.inkMuted),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(color: AppColors.inkMuted))),
      ]),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label, this.icon, this.color = AppColors.ink});
  final String value;
  final String label;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) Icon(icon, size: 20, color: color),
          if (icon != null) const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: color, height: 1)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AppColors.inkMuted, fontSize: 13, height: 1.2)),
        ]),
      ),
    );
  }
}

/// Filled button that shows a spinner while [onPressed] runs.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.icon, this.color});
  final String label;
  final IconData? icon;
  final Color? color;
  final Future<void> Function()? onPressed;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[Icon(widget.icon), const SizedBox(width: 8)],
            Flexible(child: Text(widget.label, overflow: TextOverflow.ellipsis)),
          ]);
    return FilledButton(
      style: widget.color != null ? FilledButton.styleFrom(backgroundColor: widget.color) : null,
      onPressed: (_busy || widget.onPressed == null) ? null : _run,
      child: child,
    );
  }
}

class PhotoStrip extends StatelessWidget {
  const PhotoStrip(this.urls, {super.key});
  final List urls;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => showPhotoViewer(context, urls, initial: i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(Api.instance.resolve(urls[i] as String),
                width: 120, height: 96, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                    width: 120, color: AppColors.line, child: const Icon(Icons.broken_image_outlined))),
          ),
        ),
      ),
    );
  }
}
