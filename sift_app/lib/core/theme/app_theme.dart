import 'package:flutter/material.dart';

import 'app_colors.dart';

/// App-wide theme. Inter is bundled as a variable font (see pubspec) so there
/// is no runtime font fetch — avoids the first-paint text flash.
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.green,
        secondary: AppColors.blue,
        surface: Colors.white,
      ),
      textTheme: base.textTheme.apply(
        fontFamily: 'Inter',
        bodyColor: AppColors.dark,
        displayColor: AppColors.dark,
      ),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Inter'),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
  }
}
