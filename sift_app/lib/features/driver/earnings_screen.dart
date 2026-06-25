import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/repositories/application_repository.dart';
import '../../data/repositories/ledger_repository.dart';
import '../auth/session_controller.dart';
import '../payments/checkout_webview_screen.dart';

/// Driver earnings: today/week totals, outstanding cash commission (with
/// in-app settlement), and the per-trip ledger. Card earnings settle straight
/// to the driver's bank via the Paystack split.
class EarningsScreen extends ConsumerStatefulWidget {
  const EarningsScreen({super.key});

  @override
  ConsumerState<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends ConsumerState<EarningsScreen> {
  bool _paying = false;
  bool? _hasPayout;

  @override
  void initState() {
    super.initState();
    _checkPayout();
  }

  Future<void> _checkPayout() async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    final has = await ref.read(applicationRepositoryProvider).hasPayout(uid);
    if (mounted) setState(() => _hasPayout = has);
  }

  Future<void> _payDebt() async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    setState(() => _paying = true);
    try {
      final repo = ref.read(ledgerRepositoryProvider);
      final before = await repo.watchBalance(uid).first;
      final url = await repo.initDebtPayment();
      if (!mounted) return;
      final doneSignal =
          repo.watchBalance(uid).where((b) => b < before).map((_) {});
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CheckoutWebViewScreen(
            url: url, title: 'Pay Sift commission', doneSignal: doneSignal),
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not start the payment.')));
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(sessionProvider).uid;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.dark),
          onPressed: () => context.pop(),
        ),
        title: const Text('Earnings',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<LedgerEntry>>(
              stream: ref.read(ledgerRepositoryProvider).watchEntries(uid),
              builder: (context, entriesSnap) {
                final entries =
                    entriesSnap.data ?? const <LedgerEntry>[];
                return StreamBuilder<double>(
                  stream:
                      ref.read(ledgerRepositoryProvider).watchBalance(uid),
                  builder: (context, balSnap) {
                    final balance = balSnap.data ?? 0;
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      children: [
                        _totalsCard(entries),
                        const SizedBox(height: 12),
                        if (_hasPayout == false) _payoutBanner(),
                        if (balance >= 1) _debtCard(balance),
                        const SizedBox(height: 12),
                        const Text('Activity',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        if (entries.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 30),
                            child: Center(
                              child: Text('Your trip earnings will appear here.',
                                  style: TextStyle(color: AppColors.muted)),
                            ),
                          ),
                        for (final e in entries) _entryTile(e),
                      ],
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _totalsCard(List<LedgerEntry> entries) {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final weekStart = dayStart.subtract(Duration(days: now.weekday - 1));

    double today = 0, week = 0;
    for (final e in entries) {
      final earning = e.driverEarning ?? 0;
      final at = e.createdAt;
      if (!e.isTrip || earning <= 0 || at == null) continue;
      if (!at.isBefore(dayStart)) today += earning;
      if (!at.isBefore(weekStart)) week += earning;
    }

    Widget stat(String label, double v) => Expanded(
          child: Column(
            children: [
              Text('R${v.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xCCFFFFFF))),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22),
      decoration: BoxDecoration(
        color: AppColors.green,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          stat('Today', today),
          Container(width: 1, height: 38, color: const Color(0x44FFFFFF)),
          stat('This week', week),
        ],
      ),
    );
  }

  Widget _payoutBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF6E9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEAD9B0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_balance, color: Color(0xFFB7791F)),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
                'Add your bank details to receive card-trip payouts directly.',
                style: TextStyle(fontSize: 13.5)),
          ),
          TextButton(
            onPressed: () async {
              await context.push(AppRouter.payoutDetails);
              _checkPayout();
            },
            child: const Text('Add',
                style: TextStyle(
                    color: AppColors.green, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _debtCard(double balance) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.selectedFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.selectedBorder, width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('R${balance.toStringAsFixed(2)} owed to Sift',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                const Text('Commission from your cash trips',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.muted)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: _paying ? null : _payDebt,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: _paying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Pay now',
                    style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(LedgerEntry e) {
    final (IconData icon, String title, String amountText, Color color) =
        switch (e.type) {
      'trip_earning_card' => (
          Icons.credit_card,
          'Card trip',
          '+R${(e.driverEarning ?? 0).toStringAsFixed(0)}',
          AppColors.green
        ),
      'cash_commission_due' => (
          Icons.payments_outlined,
          'Cash trip',
          '+R${(e.driverEarning ?? 0).toStringAsFixed(0)}',
          AppColors.dark
        ),
      'debt_payment' => (
          Icons.check_circle_outline,
          'Commission paid',
          '-R${(e.amount ?? -e.balanceDelta).toStringAsFixed(0)}',
          AppColors.muted
        ),
      _ => (
          Icons.tune,
          'Adjustment',
          'R${e.balanceDelta.toStringAsFixed(0)}',
          AppColors.muted
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (e.type == 'cash_commission_due')
                  Text(
                      'R${(e.commission ?? 0).toStringAsFixed(0)} commission added',
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.muted)),
                Text(_when(e.createdAt),
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.muted)),
              ],
            ),
          ),
          Text(amountText,
              style: TextStyle(
                  fontSize: 15.5, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }

  static String _when(DateTime? t) {
    if (t == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${t.day} ${months[t.month - 1]} · '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
