import 'package:flutter/material.dart';

class AppFonts {
  AppFonts._();

  static const String body = 'Pretendard';
  static const String display = 'MaruBuri';
}

class AppColors {
  AppColors._();

  static const Color background = Color(0xFFFAF7F2);
  static const Color surface = Color(0xFFFFFFFF);

  static const Color ink = Color(0xFF1C1B19);
  static const Color inkSecondary = Color(0xFF6B675F);

  static const Color seal = Color(0xFFC8372D);
  static const Color sealPressed = Color(0xFFA82C24);

  static const Color divider = Color(0xFFE8E2D8);

  static const Color wood = Color(0xFF3A7D5C);
  static const Color fire = Color(0xFFC8372D);
  static const Color earth = Color(0xFFC99A3C);
  static const Color metal = Color(0xFF8C8C88);
  static const Color water = Color(0xFF2E4A62);

  static const Color primary = seal;
  static const Color primaryDark = sealPressed;
  static const Color secondary = inkSecondary;

  static const Color textPrimary = ink;
  static const Color textSecondary = inkSecondary;
  static const Color border = divider;
  static const Color error = sealPressed;
  static const Color white = surface;
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  AppRadius._();

  static const double card = 20;
  static const double button = 14;
  static const double chip = 999;
  static const double sheet = 28;
}

class AppDurations {
  AppDurations._();

  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 280);
  static const Duration emphasis = Duration(milliseconds: 550);
}

class AppCurves {
  AppCurves._();

  static const Curve standard = Curves.easeOutCubic;
}
