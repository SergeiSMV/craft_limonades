import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';

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
