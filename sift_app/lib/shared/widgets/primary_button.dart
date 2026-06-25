import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// The app's primary CTA — green pill, disabled at 40% (Sift design system).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onPressed != null;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: active ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          disabledBackgroundColor: AppColors.green.withValues(alpha: 0.4),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
