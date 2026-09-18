import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api.dart';
import '../../services/sound.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'offer_sheet.dart';

/// Full-screen alarm for batch-1 candidates (FR-5.6, NFR-7): red pulsing screen,
/// siren and vibration for the 30-second alarm window. After that the offer
/// stays in "Permintaan relawan" as a normal request.
class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key, required this.offer});
  final Json offer;

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  Timer? _ticker;
  int _secondsLeft = 30;

  @override
  void initState() {
    super.initState();
    final sent = parseTime(widget.offer['alarm_sent_at']);
    final total = 30;
    _secondsLeft = sent == null ? total : (total - DateTime.now().difference(sent).inSeconds).clamp(0, total);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, 999));
      if (_secondsLeft == 0) Sound.instance.stopAlarm();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    Sound.instance.stopAlarm();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(AppColors.primaryDark, AppColors.brand, _pulse.value)!,
                AppColors.primaryDark,
              ],
            ),
          ),
          child: child,
        ),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(children: [
                const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('PANGGILAN DARURAT',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                ),
                if (_secondsLeft > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(999)),
                    child: Text('$_secondsLeft d',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
                  ),
                IconButton(
                  tooltip: 'Bisukan',
                  onPressed: Sound.instance.stopAlarm,
                  icon: const Icon(Icons.volume_off_rounded, color: Colors.white),
                ),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: OfferDetails(offer: widget.offer, onDark: true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(children: [
                Text(
                  _secondsLeft > 0
                      ? 'Anda termasuk relawan terdekat dengan skill yang cocok.'
                      : 'Alarm selesai. Anda masih bisa menerima tugas ini.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                OfferActions(offer: widget.offer, onDark: true, onDone: () => Navigator.of(context).maybePop()),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
