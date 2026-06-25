import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../../data/repositories/ride_repository.dart';
import '../auth/session_controller.dart';
import 'receipt_screen.dart';

/// Past trips, newest first — role-aware (rider sees their rides, driver sees
/// driven rides with earnings). Tap → full receipt.
class TripHistoryScreen extends ConsumerWidget {
  const TripHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final uid = session.uid;
    final isDriver = session.isDriver;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Your trips',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<Ride>>(
              stream: isDriver
                  ? ref.read(rideRepositoryProvider).historyForDriver(uid)
                  : ref.read(rideRepositoryProvider).historyForRider(uid),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child:
                          CircularProgressIndicator(color: AppColors.green));
                }
                final rides = (snap.data ?? const <Ride>[])
                    .where((r) =>
                        r.status == RideStatus.completed ||
                        r.status == RideStatus.cancelled)
                    .toList();
                if (rides.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.route, size: 44, color: AppColors.muted),
                        SizedBox(height: 10),
                        Text('No trips yet',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.dark)),
                        SizedBox(height: 4),
                        Text('Your completed trips will appear here.',
                            style: TextStyle(color: AppColors.muted)),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  itemCount: rides.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.line),
                  itemBuilder: (context, i) =>
                      _tile(context, rides[i], isDriver),
                );
              },
            ),
    );
  }

  Widget _tile(BuildContext context, Ride r, bool isDriver) {
    final cancelled = r.status == RideStatus.cancelled;
    final amount = isDriver ? (r.driverEarning ?? 0) : r.displayFare;
    return InkWell(
      onTap: () => context.push(AppRouter.receipt, extra: r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: cancelled ? AppColors.field : AppColors.selectedFill,
                shape: BoxShape.circle,
              ),
              child: Icon(
                cancelled ? Icons.close : Icons.check,
                size: 20,
                color: cancelled ? AppColors.muted : AppColors.green,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.destinationLabel.isEmpty ? 'Trip' : r.destinationLabel,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    cancelled ? 'Cancelled' : _when(r.createdAt),
                    style: TextStyle(
                        fontSize: 13,
                        color: cancelled
                            ? const Color(0xFFE0524D)
                            : AppColors.muted),
                  ),
                ],
              ),
            ),
            if (!cancelled)
              Text(
                isDriver
                    ? '+R${amount.toStringAsFixed(0)}'
                    : 'R${amount.toStringAsFixed(0)}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
          ],
        ),
      ),
    );
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]} · $hh:$mm';
  }
}

/// Re-exported so the router only imports one file for history + receipt.
typedef TripReceiptScreen = ReceiptScreen;
