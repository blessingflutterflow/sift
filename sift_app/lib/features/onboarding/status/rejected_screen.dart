import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../auth/session_controller.dart';

/// Driver application rejected — shows the admin's reason and lets them
/// resubmit their documents.
class RejectedScreen extends ConsumerWidget {
  const RejectedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = ref.watch(sessionProvider).rejectionReason;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  color: Color(0xFFFDE8E8),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.error_outline,
                    size: 48, color: Color(0xFFE0524D)),
              ),
              const SizedBox(height: 28),
              const Text(
                'Application not approved',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.dark,
                ),
              ),
              const SizedBox(height: 12),
              if (reason != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.field,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Reason',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.muted)),
                      const SizedBox(height: 4),
                      Text(reason,
                          style: const TextStyle(
                              fontSize: 15, color: AppColors.dark, height: 1.4)),
                    ],
                  ),
                ),
              const Spacer(),
              PrimaryButton(
                label: 'Resubmit documents',
                onPressed: () => context.go(AppRouter.driverDocuments),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
