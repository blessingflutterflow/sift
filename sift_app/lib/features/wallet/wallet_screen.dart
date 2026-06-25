import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/repositories/wallet_repository.dart';
import '../auth/session_controller.dart';
import '../payments/checkout_webview_screen.dart';

/// Rider wallet (Screens 10–12): prepaid balance, top up via Paystack, and a
/// history of top-ups and ride payments. Pay-with-wallet is selected on the
/// ride-options screen; this is where the balance is managed.
class WalletScreen extends ConsumerStatefulWidget {
  const WalletScreen({super.key});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  bool _busy = false;

  static const _quickAmounts = [50.0, 100.0, 200.0, 500.0];

  Future<void> _topUp() async {
    final amount = await _askAmount();
    if (amount == null || !mounted) return;

    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    final email = ref.read(sessionProvider).email;
    final repo = ref.read(walletRepositoryProvider);

    setState(() => _busy = true);
    try {
      final before = await repo.balance(uid);
      final url = await repo.initTopup(amount, email: email);
      if (!mounted) return;
      // Pop the checkout once the webhook credits the wallet.
      final doneSignal = repo
          .watchBalance(uid)
          .where((b) => b > before)
          .map((_) {});
      await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CheckoutWebViewScreen(
          url: url,
          title: 'Top up your wallet',
          doneSignal: doneSignal,
        ),
      ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start the top-up. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Amount picker: quick chips + a custom field. Returns ZAR or null.
  Future<double?> _askAmount() {
    double? selected;
    final controller = TextEditingController();
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Top up amount',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _quickAmounts.map((a) {
                  final on = selected == a;
                  return ChoiceChip(
                    label: Text('R${a.toStringAsFixed(0)}'),
                    selected: on,
                    showCheckmark: false,
                    selectedColor: AppColors.selectedFill,
                    side: BorderSide(
                        color: on ? AppColors.selectedBorder : AppColors.line),
                    labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: on ? AppColors.selectedBorder : AppColors.dark),
                    onSelected: (_) => setSheet(() {
                      selected = a;
                      controller.clear();
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                ],
                onChanged: (_) => setSheet(() => selected = null),
                decoration: InputDecoration(
                  prefixText: 'R ',
                  hintText: 'Other amount',
                  filled: true,
                  fillColor: AppColors.field,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.green, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text('Minimum R20 · Maximum R5000',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27)),
                  ),
                  onPressed: () {
                    final custom = double.tryParse(controller.text);
                    final amount = selected ?? custom;
                    if (amount == null || amount < 20 || amount > 5000) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(
                            content: Text('Enter an amount between R20 and R5000.')),
                      );
                      return;
                    }
                    Navigator.pop(sheetContext, amount);
                  },
                  child: const Text('Continue to payment',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(sessionProvider).uid;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: const Text('Wallet',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : Column(
              children: [
                _balanceCard(uid),
                const SizedBox(height: 8),
                Expanded(child: _history(uid)),
              ],
            ),
    );
  }

  Widget _balanceCard(String uid) {
    return StreamBuilder<double>(
      stream: ref.read(walletRepositoryProvider).watchBalance(uid),
      builder: (context, snap) {
        final balance = snap.data ?? 0;
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.green,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sift wallet balance',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 6),
              Text('R${balance.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _topUp,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.green))
                      : const Icon(Icons.add),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppColors.green,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25)),
                  ),
                  label: const Text('Top up',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _history(String uid) {
    return StreamBuilder<List<WalletEntry>>(
      stream: ref.read(walletRepositoryProvider).watchEntries(uid),
      builder: (context, snap) {
        final entries = snap.data ?? const <WalletEntry>[];
        if (entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('No wallet activity yet.\nTop up to pay for rides with your wallet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, height: 1.5)),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: entries.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: AppColors.line),
          itemBuilder: (context, i) => _entryTile(entries[i]),
        );
      },
    );
  }

  Widget _entryTile(WalletEntry e) {
    final credit = e.isCredit;
    final title = e.type == 'topup' ? 'Top up' : 'Ride payment';
    final amount =
        '${credit ? '+' : '−'}R${e.balanceDelta.abs().toStringAsFixed(2)}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: credit ? AppColors.selectedFill : AppColors.field,
        child: Icon(credit ? Icons.add : Icons.directions_car,
            color: credit ? AppColors.green : AppColors.muted, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(_when(e.createdAt),
          style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      trailing: Text(amount,
          style: TextStyle(
              fontWeight: FontWeight.w800,
              color: credit ? AppColors.green : AppColors.dark)),
    );
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    final d = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
  }
}
