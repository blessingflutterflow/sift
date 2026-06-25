import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/session.dart';
import '../../../data/repositories/application_repository.dart';
import '../../auth/session_controller.dart';

/// Driver awaiting admin review. With the backend live, this watches the
/// Firestore `applications/{uid}.status` and routes automatically when the
/// admin approves/rejects on the web dashboard. In mock mode, demo buttons
/// stand in for that decision.
class PendingScreen extends ConsumerStatefulWidget {
  const PendingScreen({super.key});

  @override
  ConsumerState<PendingScreen> createState() => _PendingScreenState();
}

class _PendingScreenState extends ConsumerState<PendingScreen>
    with SingleTickerProviderStateMixin {
  StreamSubscription<ApprovalStatus>? _sub;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    final uid = ref.read(sessionProvider).uid;
    if (AppConfig.useBackend && uid != null) {
      _sub = ref
          .read(applicationRepositoryProvider)
          .watchStatus(uid)
          .listen(_onStatus);
    }
  }

  void _onStatus(ApprovalStatus status) {
    if (!mounted) return;
    if (status == ApprovalStatus.approved) {
      context.go(AppRouter.driverHome);
    } else if (status == ApprovalStatus.rejected) {
      context.go(AppRouter.rejected);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              ScaleTransition(
                scale: Tween<double>(begin: 1.0, end: 1.08).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    color: AppColors.selectedFill,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.hourglass_top,
                      size: 48, color: AppColors.green),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Application under review',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.dark,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "We're checking your documents. This usually takes 24–48 "
                'hours. We will notify you as soon as you are approved.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15, color: AppColors.muted, height: 1.5),
              ),
              const Spacer(),
              if (!AppConfig.useBackend) _demoControls(context, ref),
            ],
          ),
        ),
      ),
    );
  }

  Widget _demoControls(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const Divider(color: AppColors.line),
        const SizedBox(height: 8),
        const Text('Demo: simulate the admin decision',
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  ref
                      .read(sessionProvider.notifier)
                      .mockReject('Your licence photo was blurry.');
                  context.go(AppRouter.rejected);
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.dark,
                  side: const BorderSide(color: AppColors.line),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28)),
                ),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  ref.read(sessionProvider.notifier).mockApprove();
                  context.go(AppRouter.driverHome);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28)),
                ),
                child: const Text('Approve'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
