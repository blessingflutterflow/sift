import 'package:flutter/material.dart';

/// Design tokens taken 1:1 from designs/styles.css `:root`.
class AppColors {
  AppColors._();

  // Brand colour: orange (client preference). Kept named `green` so the whole
  // app — which references this token everywhere — flips in one place.
  static const Color green = Color(0xFFFF6B2C); // brand orange
  static const Color dark = Color(0xFF2D2E39); // --dark
  static const Color muted = Color(0xFF777983); // --muted
  static const Color line = Color(0xFFECECF0); // --line
  static const Color panel = Color(0xFFFFFFFF); // --panel
  static const Color soft = Color(0xFFF5F5F7); // --soft
  static const Color blue = Color(0xFF4C56F4); // --blue

  // Extra shades used across the screens.
  static const Color statusText = Color(0xFF030303);
  static const Color field = Color(0xFFF4F4F6); // input backgrounds
  static const Color sheetField = Color(0xFFF7F7F8);
  static const Color batteryYellow = Color(0xFFF5CA32);
  static const Color keyboardBg = Color(0xFFCFD2D8);
  static const Color bubble = Color(0xFF292A37);
  static const Color arrive = Color(0xFF5A63FF);
  static const Color selectedFill = Color(0xFFFFE7D6); // light orange tint
  static const Color selectedBorder = Color(0xFFE2551C); // dark orange
  static const Color etaGreen = Color(0xFFE85D1C); // (orange now)
  static const Color mapBg = Color(0xFFE9F1E5);
}
