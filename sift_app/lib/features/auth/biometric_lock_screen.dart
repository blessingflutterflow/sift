import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../data/services/biometric_service.dart';
import 'session_controller.dart';

/// The biometric unlock gate for returning users (Screen 2). Shown at launch
/// when the user has enabled app lock; auto-prompts the device biometric sheet
/// and, on success, continues to [destination]. Sign out is the escape hatch.
class BiometricLockScreen extends ConsumerStatefulWidget {
  const BiometricLockScreen({super.key, required this.destination});

  /// Where to go once the user is verified.
  final String destination;

  @override
  ConsumerState<BiometricLockScreen> createState() =>
      _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await ref.read(biometricServiceProvider).authenticate();
    if (!mounted) return;
    if (ok) {
      context.go(widget.destination);
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await ref.read(sessionProvider.notifier).signOut();
    if (mounted) context.go(AppRouter.verification);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: AppColors.selectedFill,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.fingerprint,
                    size: 52, color: AppColors.green),
              ),
              const SizedBox(height: 28),
              const Text(
                'Welcome back',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.dark,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Unlock Sift with your fingerprint or face to continue.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 16, color: AppColors.muted, height: 1.5),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _busy ? null : _unlock,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    disabledBackgroundColor:
                        AppColors.green.withValues(alpha: 0.4),
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                        )
                      : const Text('Unlock',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _signOut,
                child: const Text('Sign out instead',
                    style: TextStyle(
                        color: AppColors.muted, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
