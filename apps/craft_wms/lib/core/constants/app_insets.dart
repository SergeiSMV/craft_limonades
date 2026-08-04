import 'package:flutter/material.dart';

/// Константы для отступов.
abstract final class AppInsets {
  //* --- All ------------------------------------------------------------- *//
  static const EdgeInsets all16 = EdgeInsets.all(16);
  static const EdgeInsets all24 = EdgeInsets.all(24);
  static const EdgeInsets all32 = EdgeInsets.all(32);
  static const EdgeInsets all60 = EdgeInsets.all(60); // панель формы входа
  static const EdgeInsets all80 = EdgeInsets.all(80); // бренд-панель входа

  //* --- Symmetric -------------------------------------------------------- *//
  static const EdgeInsets v4 = EdgeInsets.symmetric(vertical: 4);
  static const EdgeInsets h32 = EdgeInsets.symmetric(horizontal: 32); // хедер портала
  static const EdgeInsets h32v24 = EdgeInsets.symmetric(horizontal: 32, vertical: 24);

  //* --- Веб-портал (сайдбар) --------------------------------------------- *//
  static const EdgeInsets menuList = EdgeInsets.symmetric(vertical: 20); // прокручиваемое меню
  static const EdgeInsets menuItem = EdgeInsets.symmetric(horizontal: 24, vertical: 14); // пункт меню
  static const EdgeInsets sectionTitle = EdgeInsets.fromLTRB(24, 0, 24, 12); // заголовок секции

  //* --- Веб-портал (контент) --------------------------------------------- *//
  static const EdgeInsets uploadZone = EdgeInsets.symmetric(horizontal: 40, vertical: 48); // зона загрузки
  static const EdgeInsets badge = EdgeInsets.symmetric(horizontal: 12, vertical: 4); // пилюля-бейдж
}
