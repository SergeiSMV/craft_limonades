import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/auth/profile.dart';
import '../../../core/auth/rights.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/di/injection.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/sync/data_versions.dart';
import '../widgets/shell/nav_item.dart';
import '../widgets/shell/portal_header.dart';
import '../widgets/shell/portal_sidebar.dart';
import '../widgets/tabs/cells_tab.dart';
import '../widgets/tabs/documents_tab.dart';
import '../widgets/tabs/inventory_tab.dart';
import '../widgets/tabs/nomenclature_tab.dart';
import '../widgets/tabs/picking_tab.dart';
import '../widgets/tabs/problems_tab.dart';
import '../widgets/tabs/settings_tab.dart';
import '../widgets/tabs/stock_tab.dart';

/// Оболочка портала после входа: сайдбар (меню по секциям + профиль), шапка с заголовком
/// раздела и область вкладки. Плоская, по Shopify Polaris (ADHOC-56); уже порога md
/// ([AppSizes.kPortalCompactWidth]) меню уходит в выдвижную панель. Части - в `widgets/shell/`.
class PortalShell extends StatefulWidget {
  const PortalShell({super.key, required this.profile});

  /// Профиль вошедшего (имя + должность и права) - для карточки в сайдбаре и меню.
  final Profile profile;

  /// Есть ли что показать: хоть одно действие портала (ADHOC-50) - отдельного «входа в
  /// портал» нет, в него пускает любой отмеченный раздел.
  static bool hasSections(Profile p) => p.can(Rights.portal);

  @override
  State<PortalShell> createState() => _PortalShellState();
}

class _PortalShellState extends State<PortalShell> {
  int _selected = 0;

  /// Меню по секциям (порядок из ТЗ/макета) - только разделы, где у должности есть хоть одно
  /// действие (ADHOC-50); действия внутри раздела - тоже по правам. Секция без разделов не
  /// показывается. «Сборка» - с P9: прав на неё пока нет.
  List<NavSection> get _sections {
    final p = widget.profile;
    final receipt = docRights(
      p,
      Rights.receiptView,
      Rights.receiptDownload,
      Rights.receiptPost,
    );
    final movement = docRights(
      p,
      Rights.movementView,
      Rights.movementDownload,
      Rights.movementPost,
    );
    final stocktakeDocs = docRights(
      p,
      Rights.stocktakeDocView,
      Rights.stocktakeDocDownload,
      Rights.stocktakeDocPost,
    );
    final stockEntryDocs = docRights(
      p,
      Rights.stockEntryDocView,
      Rights.stockEntryDocDownload,
      Rights.stockEntryDocPost,
    );
    final stocktakes = p.can(Rights.stocktakeView, [Rights.stocktakeManage]);
    final cellsLabels = p.can(Rights.cellsLabels);
    final cellsUpload = p.can(Rights.cellsImport);
    final cellsEdit = p.can(Rights.cellsEdit);
    final settings = p.can(Rights.settingsWarehouses, [
      Rights.settingsProblemReasons,
      Rights.settingsUsers,
    ]);
    return [
      // Всё, кроме настроек, - один раздел «Склад» (ADHOC-56).
      NavSection(
        title: t.portal.menu.warehouse,
        items: [
          if (p.can(Rights.nomenclatureView, [Rights.nomenclatureImport]))
            NavItem(
              icon: Icons.inventory_2_outlined,
              label: t.portal.tabs.nomenclature,
              // ADHOC-56: справочник товаров, загрузка из 1С - кнопкой на панели.
              description: t.portal.goods.description,
              body: NomenclatureTab(
                canImport: p.can(Rights.nomenclatureImport),
                canStock: p.can(Rights.stockView),
              ),
            ),

          /// Приход
          if (p.can(Rights.stockView))
            NavItem(
              icon: Icons.warehouse_outlined,
              label: t.portal.tabs.stock,
              // ADHOC-56: товары с остатком - из снимка склада, как «Остатки» на ТСД.
              description: t.portal.stock.description,
              body: const StockTab(),
            ),
          if (receipt != null)
            NavItem(
              icon: Icons.local_shipping_outlined,
              label: t.portal.tabs.receipt,
              // P4-10: документы «Поступление» - та же вкладка документов, другая форма.
              description: t.portal.receipt.description,
              body: DocumentsTab(
                kind: 'receipt',
                empty: t.portal.receipt.empty,
                rights: receipt,
              ),
            ),

          /// Инвентаризация
          if (stocktakes || stocktakeDocs != null || stockEntryDocs != null)
            NavItem(
              icon: Icons.fact_check_outlined,
              label: t.portal.tabs.stocktake,
              // P10-05: пересчёты, документы «Инвентаризация» и «Ввод остатков».
              description: t.portal.stocktake.description,
              body: InventoryTab(
                stocktakes: stocktakes,
                canManage: p.can(Rights.stocktakeManage),
                stocktakeDocs: stocktakeDocs,
                stockEntryDocs: stockEntryDocs,
              ),
            ),
          if (cellsLabels || cellsUpload || cellsEdit)
            NavItem(
              icon: Icons.grid_view_outlined,
              label: t.portal.tabs.cells,
              // ADHOC-57: список ячеек, галочки этикеток, загрузка и печать по образцу rack_labels.
              description: t.portal.cells.description,
              body: CellsTab(
                canImport: cellsUpload,
                canLabels: cellsLabels,
                canEdit: cellsEdit,
              ),
            ),
          if (movement != null)
            NavItem(
              icon: Icons.swap_horiz,
              label: t.portal.tabs.movement,
              // P5-04: документы «Движение» (размещение, в P6 - перемещение и пополнение).
              description: t.portal.movement.description,
              body: DocumentsTab(
                kind: 'movement',
                empty: t.portal.movement.empty,
                rights: movement,
              ),
            ),
          if (p.can(Rights.pickingView, [
            Rights.pickingLoad,
            Rights.pickingDownload,
            Rights.pickingRelease,
          ]))
            NavItem(
              icon: Icons.inventory_2_outlined,
              label: t.portal.tabs.picking,
              // P8-02: загрузка «Реестра» 1С; P8-03: заказы по дате, детали, Excel, снятие.
              description: t.portal.picking.description,
              body: PickingTab(
                canView: p.can(Rights.pickingView, [Rights.pickingRelease]),
                canLoad: p.can(Rights.pickingLoad),
                canDownload: p.can(Rights.pickingDownload),
                canRelease: p.can(Rights.pickingRelease),
              ),
            ),
          if (p.can(Rights.problemsView, [Rights.problemsResolve]))
            NavItem(
              icon: Icons.report_problem_outlined,
              label: t.portal.tabs.problems,
              // P6-07-3: решение офиса по проблемам, помеченным на ТСД.
              description: t.portal.problems.description,
              body: ProblemsTab(canResolve: p.can(Rights.problemsResolve)),
            ),
        ],
      ),
      NavSection(
        title: t.portal.menu.system,
        items: [
          if (settings)
            NavItem(
              icon: Icons.settings_outlined,
              label: t.portal.tabs.settings,
              // ADHOC-29: внутренние склады; ADHOC-50: должности и пользователи.
              description: t.portal.settings.description,
              body: SettingsTab(
                warehouses: p.can(Rights.settingsWarehouses),
                problemReasons: p.can(Rights.settingsProblemReasons),
                users: p.can(Rights.settingsUsers),
                profile: p,
              ),
            ),
        ],
      ),
    ].where((s) => s.items.isNotEmpty).toList();
  }

  /// Плоский список пунктов (индекс = глобальный номер вкладки, как в IndexedStack).
  List<NavItem> get _flat => [for (final s in _sections) ...s.items];

  /// Смена активной вкладки.
  void onSelect(int index) => setState(() => _selected = index);

  /// Смена вкладки из выдвижного меню: панель закрывается, иначе она осталась бы поверх
  /// выбранной вкладки. Каркас берётся из контекста панели - без ключа, который не переживает
  /// горячую перезагрузку в вебе.
  void onSelectFromDrawer(BuildContext drawerContext, int index) {
    onSelect(index);
    Scaffold.of(drawerContext).closeDrawer();
  }

  /// Выход из портала (чистит токены → PortalApp вернёт экран входа).
  void logout() => context.read<AuthCubit>().logout();

  /// Оболочка уходит при выходе (ADHOC-60): забыть версии данных, чтобы следующий вход
  /// запомнил их заново, а не принял первый же ответ за «всё изменилось».
  @override
  void dispose() {
    getIt<DataVersions>().reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flat = _flat;
    // Узкое окно (телефон, половина экрана): постоянный сайдбар съел бы больше половины
    // ширины, поэтому меню уезжает в выдвижную панель, а в шапке появляется кнопка меню.
    // Сайдбар тот же - вторая вёрстка меню разошлась бы с первой.
    final compact =
        MediaQuery.sizeOf(context).width < AppSizes.kPortalCompactWidth;
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
            // IndexedStack - вкладки не пересоздаются (Номенклатура держит файл/отчёт).
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
              backgroundColor: AppColors.kNavBg,
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

/// Права на действия с документами вида (ADHOC-50); `null` - ни одного, раздела нет.
DocRights? docRights(Profile p, String view, String download, String post) {
  final r = (view: p.can(view), download: p.can(download), post: p.can(post));
  return r.view || r.download || r.post ? r : null;
}
