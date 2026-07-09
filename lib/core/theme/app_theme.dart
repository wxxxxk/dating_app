import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.matchPrimary,
      onPrimary: AppColors.surface,
      secondary: AppColors.inkSecondary,
      onSecondary: AppColors.surface,
      error: AppColors.error,
      onError: AppColors.surface,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    );
    const baseTextTheme = TextTheme(
      displayLarge: TextStyle(
        fontFamily: AppFonts.display,
        fontSize: 48,
        height: 1.16,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      displayMedium: TextStyle(
        fontFamily: AppFonts.display,
        fontSize: 36,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      displaySmall: TextStyle(
        fontFamily: AppFonts.display,
        fontSize: 28,
        height: 1.24,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      headlineLarge: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 28,
        height: 1.24,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 24,
        height: 1.28,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      headlineSmall: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 20,
        height: 1.32,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      titleLarge: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 20,
        height: 1.32,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      titleMedium: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 16,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      titleSmall: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      bodyLarge: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: AppColors.ink,
      ),
      bodyMedium: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: AppColors.ink,
      ),
      bodySmall: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 12,
        height: 1.45,
        fontWeight: FontWeight.w400,
        color: AppColors.inkSecondary,
      ),
      labelLarge: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      labelMedium: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      labelSmall: TextStyle(
        fontFamily: AppFonts.body,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: AppColors.inkSecondary,
      ),
    );
    final outlineBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.button),
      borderSide: const BorderSide(color: AppColors.divider),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: AppFonts.body,
      scaffoldBackgroundColor: AppColors.background,
      textTheme: baseTextTheme,
      primaryTextTheme: baseTextTheme,
      dividerColor: AppColors.divider,
      splashColor: AppColors.mint.withValues(alpha: 0.10),
      highlightColor: AppColors.mint.withValues(alpha: 0.06),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 17,
          height: 1.25,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        iconTheme: IconThemeData(color: AppColors.ink),
        actionsIconTheme: IconThemeData(color: AppColors.ink),
        toolbarHeight: 60,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: AppColors.divider),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.lg,
            ),
          ),
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.divider;
            }
            if (states.contains(WidgetState.pressed)) {
              return AppColors.mintPressed;
            }
            return AppColors.mint;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.inkSecondary;
            }
            return AppColors.onMint;
          }),
          overlayColor: WidgetStatePropertyAll(
            AppColors.onMint.withValues(alpha: 0.06),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 15,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.lg,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.divider;
            }
            if (states.contains(WidgetState.pressed)) {
              return AppColors.mintPressed;
            }
            return AppColors.mint;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return AppColors.inkSecondary;
            }
            return AppColors.onMint;
          }),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 15,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
          foregroundColor: const WidgetStatePropertyAll(AppColors.ink),
          side: const WidgetStatePropertyAll(
            BorderSide(color: AppColors.divider),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 15,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return AppColors.mintDeepPressed;
            }
            return AppColors.mintDeep;
          }),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontFamily: AppFonts.body,
              fontSize: 14,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.mint,
        disabledColor: AppColors.divider,
        secondarySelectedColor: AppColors.mint,
        checkmarkColor: AppColors.onMint,
        labelStyle: baseTextTheme.labelMedium,
        secondaryLabelStyle: baseTextTheme.labelMedium?.copyWith(
          color: AppColors.onMint,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
          side: const BorderSide(color: AppColors.divider),
        ),
        side: const BorderSide(color: AppColors.divider),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.background,
        selectedItemColor: AppColors.matchPrimary,
        unselectedItemColor: AppColors.inkSecondary,
        selectedLabelStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.background,
        indicatorColor: AppColors.mint.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 12,
            height: 1.2,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? AppColors.matchPrimary : AppColors.inkSecondary,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        hintStyle: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.inkSecondary,
        ),
        labelStyle: baseTextTheme.bodyMedium?.copyWith(
          color: AppColors.inkSecondary,
        ),
        floatingLabelStyle: baseTextTheme.labelLarge?.copyWith(
          color: AppColors.matchPrimary,
        ),
        border: outlineBorder,
        enabledBorder: outlineBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(
            color: AppColors.matchPrimary,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.background,
        modalBackgroundColor: AppColors.background,
        modalBarrierColor: Color(0x66000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
    );
  }
}
