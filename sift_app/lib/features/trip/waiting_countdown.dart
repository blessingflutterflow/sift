import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Live "driver is waiting" countdown, shown to both sides once the driver
/// arrives. Counts down from [limit] (default 5 min) starting at [since] —
/// the server-stamped `arrivedAt` — so it stays correct across app restarts.
class WaitingCountdown extends StatefulWidget {
  const WaitingCountdown({
    super.key,
    required this.since,
    required this.title,
    required this.expiredTitle,
    this.subtitle,
    this.expiredSubtitle,
    this.limit = const Duration(minutes: 5),
  });

  final DateTime since;
  final String title;
  final String expiredTitle;
  final String? subtitle;
  final String? expiredSubtitle;
  final Duration limit;

  @override
  State<WaitingCountdown> createState() => _WaitingCountdownState();
}

class _WaitingCountdownState extends State<WaitingCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.since);
    final remaining = widget.limit - elapsed;
    final expired = remaining <= Duration.zero;
    final shown = expired ? Duration.zero : remaining;
    final accent = expired ? const Color(0xFFB7791F) : AppColors.green;
    final fill = expired ? const Color(0xFFFDF6E9) : AppColors.selectedFill;
    final border = expired ? const Color(0xFFEAD9B0) : AppColors.selectedBorder;

    final mm = shown.inMinutes;
    final ss = shown.inSeconds % 60;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Icon(
                  expired ? Icons.hourglass_bottom : Icons.hourglass_top,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      expired ? widget.expiredTitle : widget.title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.dark),
                    ),
                    if ((expired ? widget.expiredSubtitle : widget.subtitle)
                        case final sub?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sub,
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.muted)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$mm:${ss.toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: expired
                  ? 1
                  : 1 - (remaining.inSeconds / widget.limit.inSeconds),
              minHeight: 5,
              color: accent,
              backgroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
