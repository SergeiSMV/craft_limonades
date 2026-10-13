import 'package:flutter/material.dart';

/// Константы для отступов.
abstract final class AppInsets {
  //* --- All ------------------------------------------------------------- *//
  static const EdgeInsets all2 = EdgeInsets.all(2);
  static const EdgeInsets all8 = EdgeInsets.all(8);
  static const EdgeInsets all12 = EdgeInsets.all(12);
  static const EdgeInsets all16 = EdgeInsets.all(16);
  static const EdgeInsets all24 = EdgeInsets.all(24);
  static const EdgeInsets all32 = EdgeInsets.all(32);
  static const EdgeInsets all60 = EdgeInsets.all(60); // панель формы входа
  static const EdgeInsets all80 = EdgeInsets.all(80); // бренд-панель входа

  //* --- Symmetric -------------------------------------------------------- *//
  static const EdgeInsets v2 = EdgeInsets.symmetric(vertical: 2);
  static const EdgeInsets v4 = EdgeInsets.symmetric(vertical: 4);
  static const EdgeInsets v8 = EdgeInsets.symmetric(vertical: 8);
  static const EdgeInsets v12 = EdgeInsets.symmetric(vertical: 12);
  static const EdgeInsets v16 = EdgeInsets.symmetric(vertical: 16);
  static const EdgeInsets h8 = EdgeInsets.symmetric(horizontal: 8);
  static const EdgeInsets h14 = EdgeInsets.symmetric(horizontal: 14);
  static const EdgeInsets h16 = EdgeInsets.symmetric(horizontal: 16);
  static const EdgeInsets h24 = EdgeInsets.symmetric(horizontal: 24);
  static const EdgeInsets h32 = EdgeInsets.symmetric(
    horizontal: 32,
  ); // хедер портала
  static const EdgeInsets h32v24 = EdgeInsets.symmetric(
    horizontal: 32,
    vertical: 24,
  );

  //* --- Top -------------------------------------------------------------- *//
  static const EdgeInsets top4 = EdgeInsets.only(top: 4);
  static const EdgeInsets top8 = EdgeInsets.only(top: 8);
  static const EdgeInsets top16 = EdgeInsets.only(top: 16);
  static const EdgeInsets top32 = EdgeInsets.only(top: 32);

  //* --- Bottom ----------------------------------------------------------- *//
  static const EdgeInsets bottom2 = EdgeInsets.only(bottom: 2);
  static const EdgeInsets bottom4 = EdgeInsets.only(bottom: 4);
  static const EdgeInsets bottom8 = EdgeInsets.only(bottom: 8);
  static const EdgeInsets bottom10 = EdgeInsets.only(bottom: 10);
  static const EdgeInsets bottom16 = EdgeInsets.only(bottom: 16);
  static const EdgeInsets bottom24 = EdgeInsets.only(bottom: 24);

  //* --- Right ------------------------------------------------------------ *//
  static const EdgeInsets right2 = EdgeInsets.only(right: 2);
  static const EdgeInsets right8 = EdgeInsets.only(right: 8);
  static const EdgeInsets right10 = EdgeInsets.only(right: 10);
  static const EdgeInsets right16 = EdgeInsets.only(right: 16);
  static const EdgeInsets right20 = EdgeInsets.only(right: 20);

  //* --- Left ------------------------------------------------------------- *//
  static const EdgeInsets left6 = EdgeInsets.only(left: 6);
  static const EdgeInsets left10 = EdgeInsets.only(left: 10);
  static const EdgeInsets left12 = EdgeInsets.only(left: 12);

  //* --- Диалоги ---------------------------------------------------------- *//
  /// Поля вокруг диалога. Дефолтные 40 по бокам на экране ТСД (360dp) съедают ширину —
  /// подписи кнопок переносятся на вторую строку.
  // Действия диалога портала: запас под тени неоморфных кнопок (ADHOC-25).
  static const EdgeInsets dialogActions = EdgeInsets.fromLTRB(24, 8, 24, 24);
  // Таблица документов (ADHOC-26): ячейка, фильтр-чип, поле поиска, поля плашки таблицы.
  static const EdgeInsets tableCell = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 14,
  );
  static const EdgeInsets filterChip = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 4,
  );
  static const EdgeInsets searchBox = EdgeInsets.symmetric(vertical: 12);
  static const EdgeInsets tablePlate = EdgeInsets.fromLTRB(20, 4, 20, 8);
  // Неоморфная кнопка с подписью (ADHOC-25/26).
  static const EdgeInsets h16v10 = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 10,
  );
  static const EdgeInsets dialogInset = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 24,
  );

  //* --- Веб-портал (сайдбар) --------------------------------------------- *//
  static const EdgeInsets menuList = EdgeInsets.symmetric(
    vertical: 20,
  ); // прокручиваемое меню
  static const EdgeInsets menuItem = EdgeInsets.symmetric(
    horizontal: 24,
    vertical: 8,
  ); // пункт меню
  // Пункт меню портала: поля вокруг пилюли — запас под тени неоморфизма (ADHOC-25).
  static const EdgeInsets menuItemOuter = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 2,
  );
  static const EdgeInsets sectionTitle = EdgeInsets.fromLTRB(
    24,
    0,
    24,
    12,
  ); // заголовок секции

  //* --- Веб-портал (контент) --------------------------------------------- *//
  static const EdgeInsets uploadZone = EdgeInsets.symmetric(
    horizontal: 40,
    vertical: 48,
  ); // зона загрузки
  /// Внутренний отступ неоморфной плашки списка — тот, что NeumorphicButton берёт по умолчанию:
  /// нажимаемые и простые плашки одного списка должны быть одной высоты (P5-05-1).
  static const EdgeInsets neumorphicTile = EdgeInsets.symmetric(
    horizontal: 18,
    vertical: 10,
  );
  static const EdgeInsets badge = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 4,
  ); // пилюля-бейдж
}
