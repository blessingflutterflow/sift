import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/ride.dart';
import '../auth/session_controller.dart';

/// Full receipt for a past trip — route, fare breakdown, payment outcome.
/// Drivers additionally see their earning vs commission.
class ReceiptScreen extends ConsumerWidget {
  const ReceiptScreen({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDriver = ref.watch(sessionProvider).isDriver;
    final r = ride;
    final cancelled = r.status == RideStatus.cancelled;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Trip receipt',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          // Header: amount + when.
          Center(
            child: Column(
              children: [
                Icon(
                  cancelled ? Icons.cancel : Icons.check_circle,
                  size: 44,
                  color: cancelled ? AppColors.muted : AppColors.green,
                ),
                const SizedBox(height: 8),
                Text(
                  cancelled
                      ? 'Cancelled'
                      : 'R${r.displayFare.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(_when(r.createdAt),
                    style: const TextStyle(color: AppColors.muted)),
              ],
            ),
          ),
          const SizedBox(height: 22),

          // Route.
          _routeRow(Icons.trip_origin, r.pickupAddress),
          Padding(
            padding: const EdgeInsets.only(left: 11),
            child: Container(width: 2, height: 18, color: AppColors.line),
          ),
          _routeRow(Icons.location_on, r.destinationLabel),
          const SizedBox(height: 22),

          // Fare breakdown.
          if (!cancelled) ...[
            const Text('Fare breakdown',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            _line('Trip fare (${r.tierName})',
                'R${(r.quotedFare ?? r.fare).toStringAsFixed(2)}'),
            if ((r.waitFee ?? 0) > 0)
              _line('Waiting time', 'R${r.waitFee!.toStringAsFixed(2)}'),
            const Divider(height: 22, color: AppColors.line),
            _line('Total', 'R${r.displayFare.toStringAsFixed(2)}', bold: true),
            const SizedBox(height: 6),
            _line('Distance', '${r.distanceKm.toStringAsFixed(1)} km'),
            _line('Payment', _paymentLabel(r)),
            if (isDriver) ...[
              const Divider(height: 22, color: AppColors.line),
              if (r.paymentMethod == 'cash') ...[
                // Cash: the driver already holds the full fare; the commission
                // is a debt, not money taken from them now.
                _line('Cash collected from rider',
                    'R${r.displayFare.toStringAsFixed(2)}'),
                _line('Commission owed to Sift',
                    '- R${(r.commission ?? 0).toStringAsFixed(2)}'),
                _line('Your earning',
                    'R${(r.driverEarning ?? 0).toStringAsFixed(2)}',
                    bold: true, green: true),
                const SizedBox(height: 6),
                const Text(
                    'You kept the full cash. The commission is added to your '
                    'Sift balance to settle in the app.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
              ] else ...[
                _line('Service fee (Sift)',
                    '- R${(r.commission ?? 0).toStringAsFixed(2)}'),
                _line('Your earning',
                    'R${(r.driverEarning ?? 0).toStringAsFixed(2)}',
                    bold: true, green: true),
              ],
            ],
          ],
          const SizedBox(height: 22),

          // People.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Colors.white,
                  child: Icon(Icons.person, color: AppColors.muted),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isDriver
                            ? r.riderName
                            : (r.driverName ?? 'Driver'),
                        style:
                            const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (!isDriver && r.driverVehicle != null)
                        Text(r.driverVehicle!,
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _paymentLabel(Ride r) {
    if (r.paymentMethod != 'card') return 'Cash';
    return switch (r.paymentStatus) {
      'paid' => 'Card · paid',
      'due' => 'Card · payment outstanding',
      _ => 'Card',
    };
  }

  Widget _routeRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 24, color: AppColors.green),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text.isEmpty ? '—' : text,
              style: const TextStyle(fontSize: 15),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _line(String label, String value,
      {bool bold = false, bool green = false}) {
    final style = TextStyle(
      fontSize: bold ? 16 : 14.5,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
      color: green ? AppColors.green : AppColors.dark,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: bold ? 16 : 14.5,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
                      color: bold ? AppColors.dark : AppColors.muted))),
          Text(value, style: style),
        ],
      ),
    );
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]} ${t.year} · $hh:$mm';
  }
}
