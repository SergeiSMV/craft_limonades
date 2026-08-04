import 'package:flutter/material.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_sizes.dart';
import '../gen/fonts.gen.dart';

/// Тема под ТСД: крупные «пальцевые» элементы (кнопки во всю ширину, высокие поля),
/// расчёт на работу пальцем/в перчатке, а не с мелкими контролами.
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSizes.kButtonHeight64), // крупная кнопка на всю ширину
        textStyle: const TextStyle(fontSize: AppSizes.kText20),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

/// Тема веб-портала (десктоп) по дизайн-макету: янтарный акцент, шрифт Inter,
/// светлый фон, скруглённые поля/кнопки. Отдельна от [buildAppTheme] — у портала
/// свой визуальный язык (не «пальцевый», как на ТСД).
ThemeData buildPortalTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.kPrimary,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.kPrimary,
    surface: AppColors.kCardBg,
    onSurface: AppColors.kTextMain,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.kBg,
    // Шрифт Inter — из бандла (assets/fonts/Inter, FontFamily.inter), без google_fonts.
    textTheme: base.textTheme
        .apply(fontFamily: FontFamily.inter, bodyColor: AppColors.kTextMain, displayColor: AppColors.kTextMain),
    // Поля ввода: залитые, скруглённые, янтарный фокус (по макету).
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.kFieldBg,
      border: const OutlineInputBorder(
        borderRadius: AppBorders.kCircular8,
        borderSide: BorderSide(color: AppColors.kBorder),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: AppBorders.kCircular8,
        borderSide: BorderSide(color: AppColors.kBorder),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: AppBorders.kCircular8,
        borderSide: BorderSide(color: AppColors.kPrimary, width: AppSizes.kIcon2),
      ),
    ),
    // Основная кнопка — янтарная, скруглённая.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.kPrimary,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular8),
        textStyle: const TextStyle(
          fontFamily: FontFamily.inter,
          fontSize: AppSizes.kText16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    // Вторичная кнопка (контур) — янтарный контур/текст.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.kPrimary,
        side: const BorderSide(color: AppColors.kPrimary),
        shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular8),
        textStyle: const TextStyle(
          fontFamily: FontFamily.inter,
          fontSize: AppSizes.kText14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.kCardBg,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: AppBorders.kCircular16,
        side: BorderSide(color: AppColors.kBorder),
      ),
    ),
  );
}
