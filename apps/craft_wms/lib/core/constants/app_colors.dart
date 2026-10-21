import 'package:flutter/material.dart';

/// Константы для цветов.
abstract final class AppColors {
  /// Фирменный лаймово-зелёный акцент (бренд «Крафтовые лимонады»).
  static const Color kGreenLime = Color(0xFF8BC34A);

  /// Фоновый цвет для неоморфного эффекта (светлый, синий-серый).
  static const Color kNeumorphicBg = Color(0xFFE9EEF5);

  //* --- Элементы неоморфизма --------------------------------------------- *//

  /// Цвет тени для неоморфного эффекта (светлый).
  static const Color kNeumorphicLight = Color(0xFFFFFFFF);

  /// Цвет тени для неоморфного эффекта (тёмный).
  static const Color kNeumorphicDark = Color(0xFFC3CEDC);

  //* --- Веб-портал (дизайн-система) -------------------------------------- *//
  // Палитра из макета: янтарь-акцент + лайм + тёмный slate + светлый фон.
  static const Color kPrimary = Color(
    0xFFF59E0B,
  ); // янтарь — основной акцент, кнопки
  static const Color kPrimaryHover = Color(0xFFD97706); // янтарь при наведении
  static const Color kPrimarySoft = Color(
    0xFFFFFBEB,
  ); // светлая заливка (иконки-плашки, hover-зоны)
  static const Color kSecondary = Color(0xFF84CC16); // лайм — логотип, аватар

  static const Color kSidebarBg = Color(
    0xFF1E293B,
  ); // тёмный сайдбар / бренд-панель
  static const Color kSidebarHover = Color(
    0xFF334155,
  ); // пункт меню при наведении/активный
  static const Color kSidebarText = Color(0xFFCBD5E1); // текст пунктов меню
  static const Color kSidebarMuted = Color(
    0xFF94A3B8,
  ); // заголовки секций, подписи на тёмном

  static const Color kBg = Color(0xFFF1F5F9); // фон рабочей области
  static const Color kCardBg = Color(
    0xFFFFFFFF,
  ); // карточки, хедер, форма входа
  static const Color kFieldBg = Color(
    0xFFF8FAFC,
  ); // фон полей ввода / зоны загрузки
  static const Color kTextMain = Color(0xFF0F172A); // основной текст
  static const Color kTextMuted = Color(0xFF64748B); // вторичный текст
  static const Color kTextSecondary = Color(0xFF475569); // заголовок строки списка
  static const Color kBorder = Color(0xFFE2E8F0); // границы карточек/полей
  static const Color kBorderDashed = Color(0xFFCBD5E1); // пунктир зоны загрузки

  // Бейджи-статусы.
  static const Color kBadgeSuccessBg = Color(0xFFDCFCE7);
  static const Color kBadgeSuccessText = Color(0xFF166534);
  static const Color kBadgeWarningBg = Color(0xFFFEF9C3);
  static const Color kBadgeWarningText = Color(0xFF854D0E);
  static const Color kBadgeInfoBg = Color(0xFFE0F2FE);
  static const Color kBadgeInfoText = Color(0xFF075985);

  static const Color kDanger = Color(
    0xFFEF4444,
  ); // ошибки, деструктивные действия

  //* --- ТСД: плитки главного меню (по макету) ---------------------------- *//
  // Цветовое кодирование операций на устройстве: крупные плитки, белый текст/иконка.
  static const Color kTileReceipt = Color(0xFF7964A2); // ПРИХОД — сиреневый
  static const Color kTileMovement = Color(0xFF2E6DA4); // ПЕРЕМЕЩЕНИЕ — синий
  static const Color kTileTasks = Color(0xFFE67E22); // ЗАДАНИЯ — оранжевый
  static const Color kTileFind = Color(0xFF6C757D); // НАЙТИ — серый
  static const Color kTileHistory = Color(0xFF5A6268); // ИСТОРИЯ — тёмно-серый
  static const Color kTileStock = Color(0xFF16A085); // ОСТАТКИ — бирюзовый
  static const Color kTileProblems = Color(0xFFC0392B); // ПРОБЛЕМЫ — красный
  static const Color kTileText = Color(0xFFFFFFFF); // текст/иконка на плитке

  //* --- Остатки ------------------------------------------------------------ *//
  /// Акцент количества в карточке остатка (зелёный «есть на складе»).
  static const Color kQtyValue = Color(0xFF16A34A);

  /// Иконка места хранения (синяя булавка) в строке остатка.
  static const Color kPlacePin = Color(0xFF2563EB);

  static const Color kStockItemBg = Color(0xFFFFF3E0); // фон карточки остатка
  static const Color kStockItemBorder = Color(
    0xFFFFCC80,
  ); // граница карточки остатка
}
