import 'package:flutter/material.dart';

/// Design tokens. Brand red comes from the logo (#FF352D); for text/buttons we
/// use a slightly deeper red so white text keeps >= 4.5:1 contrast (NFR-5).
class AppColors {
  static const brand = Color(0xFFFF352D);
  static const primary = Color(0xFFD7261E);
  static const primaryDark = Color(0xFFA8150F);
  static const primarySoft = Color(0xFFFFE9E7);

  static const ink = Color(0xFF14161A);
  static const inkMuted = Color(0xFF5B616E);
  static const line = Color(0xFFE4E6EB);
  static const surface = Color(0xFFFFFFFF);
  static const background = Color(0xFFF5F6F8);

  static const success = Color(0xFF1E8E3E);
  static const successSoft = Color(0xFFE6F4EA);
  static const warning = Color(0xFFB26A00);
  static const warningSoft = Color(0xFFFFF4E0);
  static const info = Color(0xFF1A5FB4);
  static const infoSoft = Color(0xFFE7F0FB);
}

const kFontFamily = 'NunitoSans';

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    onPrimary: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    error: AppColors.primaryDark,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: kFontFamily);
  final text = base.textTheme.apply(bodyColor: AppColors.ink, displayColor: AppColors.ink);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.2),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.4),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.4),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          fontFamily: kFontFamily, fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.ink),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: kFontFamily, fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.line, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: kFontFamily, fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(fontFamily: kFontFamily, fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.line)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 2)),
      labelStyle: const TextStyle(color: AppColors.inkMuted),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: const TextStyle(fontFamily: kFontFamily, fontWeight: FontWeight.w700, color: AppColors.ink),
      side: const BorderSide(color: AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      contentTextStyle: TextStyle(fontFamily: kFontFamily, fontSize: 15, fontWeight: FontWeight.w600),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, space: 1),
  );
}
