import 'package:flutter/material.dart';

/// Константы для радиусов скругления.
abstract final class AppBorders {
  //* --- Circular --------------------------------------------------------- *//
  static const BorderRadius kCircular6 = BorderRadius.all(Radius.circular(6)); // отметки (ADHOC-56)
  static const BorderRadius kCircular8 = BorderRadius.all(Radius.circular(8)); // поля, кнопки
  static const BorderRadius kCircular10 = BorderRadius.all(Radius.circular(10));
  static const BorderRadius kCircular12 = BorderRadius.all(Radius.circular(12)); // зона загрузки, плашки
  static const BorderRadius kCircular16 = BorderRadius.all(Radius.circular(16)); // карточки
  // Скругление шапки экрана с фон-картинкой — только нижние углы.
  static const BorderRadius kBottom10 = BorderRadius.only(
    bottomLeft: Radius.circular(10),
    bottomRight: Radius.circular(10),
  );
  static const BorderRadius kPill = BorderRadius.all(Radius.circular(99)); // бейджи-пилюли
}
