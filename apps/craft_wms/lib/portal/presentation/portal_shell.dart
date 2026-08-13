import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/auth/auth_cubit.dart';
import '../../core/auth/profile.dart';
import '../../core/constants/app_boxes.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_insets.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/gen/strings.g.dart';
import 'tabs/cells_tab.dart';
import 'tabs/inventory_tab.dart';
import 'tabs/nomenclature_tab.dart';
import 'tabs/stub_tab.dart';

/// Один пункт меню портала: иконка + подпись + тело вкладки.
class _NavItem {
  const _NavItem({required this.icon, required this.label, required this.body});

  final IconData icon;
  final String label;
  final Widget body;
}

/// Секция меню (группа пунктов под заголовком).
class _NavSection {
  const _NavSection({required this.title, required this.items});

  final String title;
  final List<_NavItem> items;
}

/// Оболочка портала после входа по дизайн-макету: тёмный сайдбар (секции + профиль)
/// + белый хедер + область контента. Рабочая вкладка одна — Номенклатура; остальные —
/// заглушки с меткой фазы.
class PortalShell extends StatefulWidget {
  const PortalShell({super.key, required this.profile});

  /// Профиль вошедшего (имя + роль) — для карточки пользователя в сайдбаре.
  final Profile profile;

  @override
  State<PortalShell> createState() => _PortalShellState();
}

class _PortalShellState extends State<PortalShell> {
  int _selected = 0;

  /// Меню по секциям (порядок из ТЗ/макета). Метки фаз — где раздел станет рабочим.
  List<_NavSection> get _sections => [
    _NavSection(
      title: t.portal.menu.operations,
      items: [
        _NavItem(
          icon: Icons.inventory_2_outlined,
          label: t.portal.tabs.nomenclature,
          body: const NomenclatureTab(),
        ),
        _NavItem(
          icon: Icons.local_shipping_outlined,
          label: t.portal.tabs.receipt,
          body: const StubTab(phase: 'P4', icon: Icons.local_shipping_outlined),
        ),
        _NavItem(
          icon: Icons.shopping_cart_checkout,
          label: t.portal.tabs.picking,
          body: const StubTab(phase: 'P9', icon: Icons.shopping_cart_checkout),
        ),
        _NavItem(
          icon: Icons.fact_check_outlined,
          label: t.portal.tabs.stocktake,
          body: const InventoryTab(),
        ),
      ],
    ),
    _NavSection(
      title: t.portal.menu.warehouse,
      items: [
        _NavItem(
          icon: Icons.grid_view_outlined,
          label: t.portal.tabs.cells,
          body: const CellsTab(),
        ),
        _NavItem(
          icon: Icons.swap_horiz,
          label: t.portal.tabs.movement,
          body: const StubTab(phase: 'P6', icon: Icons.swap_horiz),
        ),
      ],
    ),
    _NavSection(
      title: t.portal.menu.system,
      items: [
        _NavItem(
          icon: Icons.settings_outlined,
          label: t.portal.tabs.settings,
          body: const StubTab(phase: 'P8', icon: Icons.settings_outlined),
        ),
      ],
    ),
  ];

  /// Плоский список пунктов (индекс = глобальный номер вкладки, как в IndexedStack).
  List<_NavItem> get _flat => [for (final s in _sections) ...s.items];

  /// Смена активной вкладки.
  void onSelect(int index) => setState(() => _selected = index);

  /// Выход из портала (чистит токены → PortalApp вернёт экран входа).
  void logout() => context.read<AuthCubit>().logout();

  @override
  Widget build(BuildContext context) {
    final flat = _flat;
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            sections: _sections,
            selected: _selected,
            onSelect: onSelect,
            profile: widget.profile,
          ),
          Expanded(
            child: Column(
              children: [
                _Header(title: flat[_selected].label, onLogout: logout),
                Expanded(
                  child: ColoredBox(
                    color: AppColors.kBg,
                    // IndexedStack — вкладки не пересоздаются (Номенклатура держит файл/отчёт).
                    child: IndexedStack(
                      index: _selected,
                      children: [for (final item in flat) item.body],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Тёмный сайдбар: логотип, меню по секциям, карточка пользователя внизу.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sections,
    required this.selected,
    required this.onSelect,
    required this.profile,
  });

  final List<_NavSection> sections;
  final int selected;
  final ValueChanged<int> onSelect;
  final Profile profile;

  /// Инициалы для аватара: первые буквы первых двух слов имени.
  String get _initials {
    final parts = profile.fullName.trim().split(RegExp(r'\s+'));
    final letters = parts.take(2).map((p) => p.isEmpty ? '' : p[0]).join();
    return letters.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Глобальный счётчик индексов пунктов (сквозной по всем секциям).
    var globalIndex = 0;
    final menuChildren = <Widget>[];
    for (final section in sections) {
      menuChildren.add(_SectionTitle(section.title));
      for (final item in section.items) {
        final index = globalIndex++;
        menuChildren.add(
          _MenuItem(
            icon: item.icon,
            label: item.label,
            active: index == selected,
            onTap: () => onSelect(index),
          ),
        );
      }
      menuChildren.add(AppBoxes.kHeight16);
    }

    return Container(
      width: AppSizes.kSidebarWidth,
      color: AppColors.kSidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Логотип.
          Container(
            padding: AppInsets.all24,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white24)),
            ),
            child: Row(
              children: [
                const Icon(Icons.eco, color: AppColors.kSecondary, size: AppSizes.kIcon28),
                AppBoxes.kWidth12,
                Expanded(
                  child: Text(
                    t.portal.brand,
                    style: const TextStyle(
                      color: AppColors.kPrimary,
                      fontSize: AppSizes.kText22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Меню.
          Expanded(
            child: SingleChildScrollView(
              padding: AppInsets.menuList,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: menuChildren),
            ),
          ),
          // Карточка пользователя.
          Container(
            padding: AppInsets.all24,
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white24)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: AppSizes.kAvatar / 2,
                  backgroundColor: AppColors.kSecondary,
                  child: Text(
                    _initials,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppSizes.kText14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        profile.role,
                        style: const TextStyle(color: AppColors.kPrimary, fontSize: AppSizes.kText12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Заголовок секции меню (мелкий, приглушённый, капсом).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.sectionTitle,
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.kSidebarMuted,
          fontSize: AppSizes.kText12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Пункт меню: иконка + подпись, активный — янтарная полоса слева + подсветка фона.
class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.white : AppColors.kSidebarText;
    return Material(
      color: active ? AppColors.kSidebarHover : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.kSidebarHover,
        child: Container(
          padding: AppInsets.menuItem,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: active ? AppColors.kPrimary : Colors.transparent,
                width: AppSizes.kActiveBarWidth,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: AppSizes.kIcon20),
              AppBoxes.kWidth16,
              Text(
                label,
                style: TextStyle(color: color, fontSize: AppSizes.kText15, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Верхняя панель контента: заголовок текущей вкладки + выход.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onLogout});

  final String title;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.kHeaderHeight,
      padding: AppInsets.h32,
      // Цвет — внутри decoration (нельзя одновременно color и decoration у Container).
      decoration: const BoxDecoration(
        color: AppColors.kCardBg,
        border: Border(bottom: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: AppSizes.kText20, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            onPressed: onLogout,
            icon: const Icon(Icons.logout, color: AppColors.kTextMuted),
            tooltip: t.portal.shell.logout,
          ),
        ],
      ),
    );
  }
}
