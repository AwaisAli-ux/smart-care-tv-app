import 'package:flutter/material.dart';

class AppColors {
  // Brand Colors
  static const Color accent = Color(0xFFE8401C);
  static const Color accentDark = Color(0xFFC0321A);
  static const Color accentLight = Color(0xFFFF6B47);

  // Backgrounds
  static const Color bg = Color(0xFF06080F);
  static const Color bg2 = Color(0xFF0C1018);
  static const Color bg3 = Color(0xFF111620);
  static const Color bg4 = Color(0xFF182030);

  // Borders
  static const Color border = Color(0xFF1F2C42);
  static const Color border2 = Color(0xFF243350);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xBFFFFFFF);
  static const Color textTertiary = Color(0x66FFFFFF);

  // Status
  static const Color live = Color(0xFFE8401C);
  static const Color success = Color(0xFF1DBD6A);
  static const Color gold = Color(0xFFF5A623);
}

class AppTheme {
  static ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Inter',
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.accentDark,
          surface: AppColors.bg2,
          onPrimary: Colors.white,
          onSurface: AppColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bg2,
          elevation: 0,
          titleTextStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.5),
          displayMedium: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: -0.5),
          titleLarge: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary),
          titleMedium: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary),
          titleSmall: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary),
          bodyLarge: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondary,
              height: 1.6),
          bodyMedium: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondary),
          bodySmall: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.textTertiary),
          labelLarge: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: const TextStyle(
                fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.bg3,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.accent, width: 2.5),
          ),
          hintStyle: const TextStyle(
              color: AppColors.textTertiary, fontFamily: 'Inter'),
          labelStyle: const TextStyle(
              color: AppColors.accent,
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w500),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        snackBarTheme: const SnackBarThemeData(
          contentTextStyle: TextStyle(
            color: Colors.white,
            fontFamily: 'Inter',
            fontSize: 14,
          ),
          backgroundColor: AppColors.bg4,
        ),
      );
}
