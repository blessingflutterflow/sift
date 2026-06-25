import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// A row of 5 tappable stars.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 40,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < value;
        return IconButton(
          onPressed: () => onChanged(i + 1),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          constraints: const BoxConstraints(),
          icon: Icon(
            filled ? Icons.star_rounded : Icons.star_outline_rounded,
            size: size,
            color: filled ? const Color(0xFFF5B301) : AppColors.line,
          ),
        );
      }),
    );
  }
}
