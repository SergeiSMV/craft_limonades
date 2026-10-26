import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/auth/profile.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/strings.g.dart';
import '../widgets/shell/nav_item.dart';
import '../widgets/shell/portal_header.dart';
import '../widgets/shell/portal_sidebar.dart';
import '../widgets/tabs/cells_tab.dart';
import '../widgets/tabs/documents_tab.dart';
import '../widgets/tabs/inventory_tab.dart';
import '../widgets/tabs/nomenclature_tab.dart';
import '../widgets/tabs/problems_tab.dart';
import '../widgets/tabs/settings_tab.dart';
import '../widgets/tabs/stub_tab.dart';

/// Оболочка портала после входа: сайдбар (меню по секциям + профиль), шапка с заголовком
/// раздела и область вкладки. Светлая неоморфная (ADHOC-25); на узком экране меню уходит
/// в выдвижную панель. Части — в `widgets/shell/`.
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
  List<NavSection> get _sections => [
    NavSection(
      title: t.portal.menu.operations,
      items: [

        /// Номенклатура
        NavItem(
          icon: Icons.inventory_2_outlined,
          label: t.portal.tabs.nomenclature,
          body: const NomenclatureTab(),
        ),

        /// Приход
        NavItem(
          icon: Icons.local_shipping_outlined,
          label: t.portal.tabs.receipt,
          // P4-10: документы «Поступление» — та же вкладка документов, другая форма.
          description: t.portal.receipt.description,
          body: DocumentsTab(
            kind: 'receipt',
            empty: t.portal.receipt.empty,
          ),
        ),

        /// Сборка
        NavItem(
          icon: Icons.shopping_cart_checkout,
          label: t.portal.tabs.picking,
          body: const StubTab(phase: 'P9', icon: Icons.shopping_cart_checkout),
        ),

        /// Инвентаризация
        NavItem(
          icon: Icons.fact_check_outlined,
          label: t.portal.tabs.stocktake,
          // P10-05: пересчёты, документы «Инвентаризация» и «Ввод остатков».
          description: t.portal.stocktake.description,
          body: const InventoryTab(),
        ),
      ],
    ),
    NavSection(
      title: t.portal.menu.warehouse,
      items: [
        NavItem(
          icon: Icons.grid_view_outlined,
          label: t.portal.tabs.cells,
          body: const CellsTab(),
        ),
        NavItem(
          icon: Icons.swap_horiz,
          label: t.portal.tabs.movement,
          // P5-04: документы «Движение» (размещение, в P6 — перемещение и пополнение).
          description: t.portal.movement.description,
          body: DocumentsTab(
            kind: 'movement',
            empty: t.portal.movement.empty,
          ),
        ),
        NavItem(
          icon: Icons.report_problem_outlined,
          label: t.portal.tabs.problems,
          // P6-07-3: решение офиса по проблемам, помеченным на ТСД.
          description: t.portal.problems.description,
          body: const ProblemsTab(),
        ),
      ],
    ),
    NavSection(
      title: t.portal.menu.system,
      items: [
        NavItem(
          icon: Icons.settings_outlined,
          label: t.portal.tabs.settings,
          // ADHOC-29: внутренние склады («Брак», «Изолятор» …) — первый раздел настроек.
          description: t.portal.settings.description,
          body: const SettingsTab(),
        ),
      ],
    ),
  ];

  /// Плоский список пунктов (индекс = глобальный номер вкладки, как в IndexedStack).
  List<NavItem> get _flat => [for (final s in _sections) ...s.items];

  /// Смена активной вкладки.
  void onSelect(int index) => setState(() => _selected = index);

  /// Смена вкладки из выдвижного меню: панель закрывается, иначе она осталась бы поверх
  /// выбранной вкладки. Каркас берётся из контекста панели — без ключа, который не переживает
  /// горячую перезагрузку в вебе.
  void onSelectFromDrawer(BuildContext drawerContext, int index) {
    onSelect(index);
    Scaffold.of(drawerContext).closeDrawer();
  }

  /// Выход из портала (чистит токены → PortalApp вернёт экран входа).
  void logout() => context.read<AuthCubit>().logout();

  @override
  Widget build(BuildContext context) {
    final flat = _flat;
    // Узкое окно (телефон, половина экрана): постоянный сайдбар съел бы больше половины
    // ширины, поэтому меню уезжает в выдвижную панель, а в шапке появляется кнопка меню.
    // Сайдбар тот же — вторая вёрстка меню разошлась бы с первой.
    final compact = MediaQuery.sizeOf(context).width < AppSizes.kPortalCompactWidth;
    final content = Column(
      children: [
        PortalHeader(
          title: flat[_selected].label,
          description: flat[_selected].description,
          onLogout: logout,
          showMenu: compact,
        ),
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
    );
    return Scaffold(
      drawer: compact
          ? Drawer(
              width: AppSizes.kSidebarWidth,
              backgroundColor: AppColors.kBg,
              shape: const RoundedRectangleBorder(),
              child: Builder(
                builder: (drawerContext) => PortalSidebar(
                  sections: _sections,
                  selected: _selected,
                  onSelect: (index) => onSelectFromDrawer(drawerContext, index),
                  profile: widget.profile,
                ),
              ),
            )
          : null,
      body: compact
          ? content
          : Row(
              children: [
                PortalSidebar(
                  sections: _sections,
                  selected: _selected,
                  onSelect: onSelect,
                  profile: widget.profile,
                ),
                Expanded(child: content),
              ],
            ),
    );
  }
}
