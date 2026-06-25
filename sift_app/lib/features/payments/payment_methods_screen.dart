import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/session.dart';
import '../../data/repositories/payment_repository.dart';
import '../../data/repositories/user_repository.dart';
import '../auth/session_controller.dart';
import 'checkout_webview_screen.dart';

/// Rider's saved cards: list, add (Paystack vault checkout), pick default,
/// remove. Cash is always available and lives on the ride-options selector.
class PaymentMethodsScreen extends ConsumerStatefulWidget {
  const PaymentMethodsScreen({super.key});

  @override
  ConsumerState<PaymentMethodsScreen> createState() =>
      _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends ConsumerState<PaymentMethodsScreen> {
  bool _starting = false;

  Future<void> _addCard() async {
    final session = ref.read(sessionProvider);
    final uid = session.uid;
    if (uid == null) return;

    var email = session.email;
    if (email.isEmpty) {
      final entered = await _askEmail();
      if (entered == null || entered.isEmpty) return;
      email = entered;
      // Persist so future checkouts and receipts have it.
      final role = session.role ?? UserRole.rider;
      await ref.read(userRepositoryProvider).upsertProfile(
            uid: uid,
            phone: session.phone,
            role: role,
            name: session.name,
            email: email,
            status: session.status,
          );
    }

    setState(() => _starting = true);
    try {
      final repo = ref.read(paymentRepositoryProvider);
      final url = await repo.initCardSetup(email);
      if (!mounted) return;

      // Pop the WebView the moment the webhook lands the new card doc.
      final before = await repo.watchMethods(uid).first;
      final doneSignal = repo
          .watchMethods(uid)
          .where((list) => list.length > before.length)
          .map((_) {});
      if (!mounted) return;

      final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CheckoutWebViewScreen(
          url: url,
          title: 'Add card',
          doneSignal: doneSignal,
        ),
      ));
      if (ok == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Card saved. The R1 verification is auto-refunded.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not start card setup.')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<String?> _askEmail() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Your email',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Receipts and card verification are sent to your email.',
                style: TextStyle(color: AppColors.muted, fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'you@example.com',
                filled: true,
                fillColor: AppColors.field,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v);
              if (valid) Navigator.pop(dialogContext, v);
            },
            child: const Text('Continue',
                style:
                    TextStyle(color: AppColors.green, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(PaymentMethod m) async {
    final uid = ref.read(sessionProvider).uid;
    if (uid == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Remove card?',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: Text('${m.label} will be removed from your account.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child:
                const Text('Keep', style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove',
                style: TextStyle(
                    color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (yes == true) {
      await ref.read(paymentRepositoryProvider).remove(uid, m.id);
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
        title: const Text('Payment methods',
            style: TextStyle(
                color: AppColors.dark,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<PaymentMethod>>(
              stream: ref.read(paymentRepositoryProvider).watchMethods(uid),
              builder: (context, snap) {
                final methods = snap.data ?? const <PaymentMethod>[];
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    // Cash is always available.
                    _tile(
                      leading: const Icon(Icons.payments_outlined,
                          size: 26, color: AppColors.green),
                      title: 'Cash',
                      subtitle: 'Pay the driver directly',
                      trailing: null,
                    ),
                    const SizedBox(height: 4),
                    for (final m in methods) _cardTile(m),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: _starting ? null : _addCard,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.green,
                          side: const BorderSide(
                              color: AppColors.selectedBorder, width: 1.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(27)),
                        ),
                        icon: _starting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.green))
                            : const Icon(Icons.add_card),
                        label: const Text('Add card',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Cards are stored securely by Paystack — Sift never '
                      'sees your card number. Adding a card makes it your '
                      'default for trips.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.muted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _cardTile(PaymentMethod m) {
    return _tile(
      leading: const Icon(Icons.credit_card, size: 26, color: AppColors.dark),
      title: m.label,
      subtitle: m.isDefault
          ? 'Default · trips are charged to this card'
          : (m.bank.isEmpty ? 'Tap to make default' : m.bank),
      onTap: m.isDefault
          ? null
          : () async {
              final uid = ref.read(sessionProvider).uid;
              if (uid == null) return;
              final all = await ref
                  .read(paymentRepositoryProvider)
                  .watchMethods(uid)
                  .first;
              await ref
                  .read(paymentRepositoryProvider)
                  .setDefault(uid, m.id, all);
            },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.isDefault)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.selectedFill,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text('Default',
                  style: TextStyle(
                      color: AppColors.green,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 22, color: AppColors.muted),
            onPressed: () => _confirmRemove(m),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required Widget leading,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: ListTile(
        onTap: onTap,
        leading: leading,
        title: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 13, color: AppColors.muted)),
        trailing: trailing,
      ),
    );
  }
}
