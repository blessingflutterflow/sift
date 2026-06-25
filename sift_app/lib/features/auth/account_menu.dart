import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/biometric_service.dart';
import 'session_controller.dart';

/// Confirm + execute account deletion via the `deleteAccount` callable.
/// Profile, cards and places are removed server-side; trip records remain
/// for accounting.
Future<void> _confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Delete your account?',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: const Text(
          'This permanently removes your profile, saved cards and places. '
          'Trip records are kept for accounting. This cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep my account',
              style: TextStyle(color: AppColors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete',
              style: TextStyle(
                  color: Color(0xFFE0524D), fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;

  try {
    await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('deleteAccount')
        .call<Map<dynamic, dynamic>>({});
    await ref.read(sessionProvider.notifier).signOut();
    if (context.mounted) context.go(AppRouter.verification);
  } on FirebaseFunctionsException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.code == 'failed-precondition'
              ? 'Finish or cancel your active trip first.'
              : 'Could not delete your account. Try again.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not delete your account. Try again.')));
    }
  }
}

/// "App lock" toggle — enables biometric (fingerprint / Face ID) unlock at
/// launch. Hides itself entirely when the device has no usable biometrics.
/// Enabling requires one successful prompt so a user can never lock themselves
/// out with a sensor that doesn't work.
class _BiometricToggleTile extends ConsumerStatefulWidget {
  const _BiometricToggleTile();

  @override
  ConsumerState<_BiometricToggleTile> createState() =>
      _BiometricToggleTileState();
}

class _BiometricToggleTileState extends ConsumerState<_BiometricToggleTile> {
  bool _available = false;
  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(biometricServiceProvider);
    final available = await service.isAvailable();
    final enabled = available && await service.isEnabled();
    if (mounted) {
      setState(() {
        _available = available;
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final service = ref.read(biometricServiceProvider);
    if (value) {
      // Confirm the sensor works before turning the lock on.
      final ok = await service.authenticate(
          reason: 'Confirm to turn on app lock');
      if (ok) {
        await service.setEnabled(true);
        if (mounted) setState(() => _enabled = true);
      }
    } else {
      await service.setEnabled(false);
      if (mounted) setState(() => _enabled = false);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || !_available) return const SizedBox.shrink();
    return SwitchListTile(
      secondary: const Icon(Icons.fingerprint, color: AppColors.dark),
      title: const Text('App lock',
          style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('Unlock with fingerprint or face'),
      activeThumbColor: AppColors.green,
      value: _enabled,
      onChanged: _busy ? null : _toggle,
    );
  }
}

/// A small account sheet: shows who's signed in and offers sign-out.
Future<void> showAccountMenu(BuildContext context, WidgetRef ref) {
  final session = ref.read(sessionProvider);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: const Color(0xFFE6E6E8),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: AppColors.field,
              child: Icon(Icons.person, color: AppColors.muted),
            ),
            title: Text(
              session.name.isEmpty ? 'Your account' : session.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(session.phone.isEmpty ? '' : session.phone),
          ),
          const Divider(height: 1, color: AppColors.line),
          ListTile(
            leading: const Icon(Icons.route, color: AppColors.dark),
            title: const Text('Your trips',
                style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push(AppRouter.trips);
            },
          ),
          if (!session.isDriver)
            ListTile(
              leading: const Icon(Icons.event_outlined, color: AppColors.dark),
              title: const Text('Scheduled rides',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.scheduledRides);
              },
            ),
          if (session.isDriver) ...[
            ListTile(
              leading: const Icon(Icons.payments_outlined,
                  color: AppColors.dark),
              title: const Text('Earnings',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.driverEarnings);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.account_balance, color: AppColors.dark),
              title: const Text('Payout details',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.payoutDetails);
              },
            ),
          ],
          if (!session.isDriver) ...[
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: AppColors.dark),
              title: const Text('Wallet',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.wallet);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.credit_card, color: AppColors.dark),
              title: const Text('Payment methods',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.payments);
              },
            ),
            ListTile(
              leading: const Icon(Icons.star_border, color: AppColors.dark),
              title: const Text('Saved places',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(AppRouter.savedPlaces);
              },
            ),
          ],
          const _BiometricToggleTile(),
          ListTile(
            leading:
                const Icon(Icons.person_outline, color: AppColors.dark),
            title: const Text('Edit profile',
                style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push(AppRouter.editProfile);
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Color(0xFFE0524D)),
            title: const Text('Sign out',
                style: TextStyle(color: Color(0xFFE0524D))),
            onTap: () async {
              Navigator.pop(sheetContext);
              await ref.read(sessionProvider.notifier).signOut();
              if (context.mounted) context.go(AppRouter.verification);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined,
                color: AppColors.muted),
            title: const Text('Delete account',
                style: TextStyle(color: AppColors.muted, fontSize: 14)),
            onTap: () {
              Navigator.pop(sheetContext);
              _confirmDeleteAccount(context, ref);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
