import 'package:flutter/widgets.dart';

/// Один пункт меню портала: иконка + подпись + тело вкладки.
class NavItem {
  const NavItem({required this.icon, required this.label, required this.body, this.description});

  final IconData icon;
  final String label;
  final Widget body;

  /// Пояснение к разделу — под заголовком в шапке; `null` — без пояснения.
  final String? description;
}

/// Секция меню (группа пунктов под заголовком).
class NavSection {
  const NavSection({required this.title, required this.items});

  final String title;
  final List<NavItem> items;
}
