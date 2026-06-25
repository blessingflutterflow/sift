import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Shows the ride tier's car art from `assets/cars/{id}.png` once you drop the
/// PNGs in; until then it gracefully falls back to an icon (+ optional badge).
class CarImage extends StatelessWidget {
  const CarImage({
    super.key,
    required this.tierId,
    required this.fallbackIcon,
    this.badge,
    this.size = 56,
  });

  final String tierId;
  final IconData fallbackIcon;
  final IconData? badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 8,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Image.asset(
            'assets/cars/$tierId.png',
            width: size + 8,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                Icon(fallbackIcon, size: size * 0.68, color: AppColors.dark),
          ),
          if (badge != null)
            Positioned(
              right: 0,
              bottom: 2,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                    color: AppColors.green, shape: BoxShape.circle),
                child: Icon(badge, size: 12, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}
