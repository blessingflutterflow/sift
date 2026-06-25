import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ride_repository.dart';
import '../auth/session_controller.dart';

/// Rider's upcoming advance bookings (Screen 16). Lists scheduled rides with
/// their time + estimate, and lets the rider cancel before dispatch.
class ScheduledRidesScreen extends ConsumerWidget {
  const ScheduledRidesScreen({super.key});

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmt(DateTime? t) {
    if (t == null) return '';
    final d = t.toLocal();
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${_months[d.month - 1]} · $h:$m';
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, Ride r) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel scheduled ride?',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: Text('Your ride to ${r.destinationLabel} on ${_fmt(r.scheduledFor)} '
            'will be cancelled.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it',
                style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel ride',
                style: TextStyle(
                    color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await ref.read(rideRepositoryProvider).cancel(r.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not cancel. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(sessionProvider).uid;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Text('Scheduled rides',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<Ride>>(
              stream: ref.read(rideRepositoryProvider).watchScheduled(uid),
              builder: (context, snap) {
                final rides = snap.data ?? const <Ride>[];
                if (rides.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No upcoming rides.\nBook one in advance from the ride options screen.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted, height: 1.5),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rides.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => _tile(context, ref, rides[i]),
                );
              },
            ),
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, Ride r) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, size: 18, color: AppColors.green),
              const SizedBox(width: 8),
              Text(_fmt(r.scheduledFor),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16)),
              const Spacer(),
              Text('R${r.fare.toStringAsFixed(0)}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.place_outlined, size: 18, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.destinationLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.dark)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${r.tierName} · ${r.distanceKm.toStringAsFixed(1)} km',
              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _cancel(context, ref, r),
              child: const Text('Cancel',
                  style: TextStyle(
                      color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
