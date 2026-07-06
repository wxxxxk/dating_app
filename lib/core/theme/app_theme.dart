import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 앱 전역 테마 정의.
///
/// 왜 ThemeData를 따로 빼나:
/// - MaterialApp에 테마를 한 번 주입하면 버튼/입력창/글자색이 자동으로 통일된다.
/// - 화면마다 스타일을 반복해서 지정할 필요가 없어진다.
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    // ColorScheme을 기준으로 위젯들이 색을 가져가므로 seed/직접지정을 함께 구성.
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      surface: AppColors.surface,
      error: AppColors.error,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      // 한글 가독성을 위해 기본 폰트는 시스템 폰트를 사용(별도 폰트는 이후 마일스톤에서).
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
      ),
      // 입력창 기본 모양을 둥글게 통일.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}
