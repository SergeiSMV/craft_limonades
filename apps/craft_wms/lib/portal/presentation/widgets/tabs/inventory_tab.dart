import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../stocktake/stocktakes_view.dart';
import '../ui/portal_choice.dart';
import 'documents_tab.dart';

/// Вкладка «Инвентаризация» (P10-05): пересчёты склада, их документы «Инвентаризация» для 1С
/// и документы «Ввода остатков» (P-FS-09). Три вида — переключателем сверху: все они про
/// приведение учёта к полке, а документ «Инвентаризация» рождается закрытием пересчёта.
///
/// Виды и действия — по правам (ADHOC-50): пересчёты — «смотреть ход» или «заводить и
/// закрывать», документы — любое право на свой вид.
class InventoryTab extends StatefulWidget {
  const InventoryTab({
    super.key,
    required this.stocktakes,
    required this.canManage,
    this.stocktakeDocs,
    this.stockEntryDocs,
  });

  /// Показать вид «Пересчёты».
  final bool stocktakes;

  /// Заводить и закрывать пересчёты.
  final bool canManage;

  /// Права на документы «Инвентаризация» и «Ввод остатков»; `null` — вида нет.
  final DocRights? stocktakeDocs;
  final DocRights? stockEntryDocs;

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

/// Вид вкладки.
enum _View { stocktakes, documents, stockEntry }

class _InventoryTabState extends State<InventoryTab> {
  int _view = 0;

  /// Сменить вид.
  void _select(int view) => setState(() => _view = view);

  /// Доступные виды в порядке переключателя.
  List<_View> get _views => [
    if (widget.stocktakes) _View.stocktakes,
    if (widget.stocktakeDocs != null) _View.documents,
    if (widget.stockEntryDocs != null) _View.stockEntry,
  ];

  String _label(_View v) => switch (v) {
    _View.stocktakes => t.portal.stocktake.viewStocktakes,
    _View.documents => t.portal.stocktake.viewDocuments,
    _View.stockEntry => t.portal.stocktake.viewStockEntry,
  };

  @override
  Widget build(BuildContext context) {
    final views = _views;
    final view = views[_view.clamp(0, views.length - 1)];
    // Переключатель видов в плоском стиле (ADHOC-56). У документов он закреплён над их панелью
    // поиска — в общей раскладке страницы-списка; у пересчётов — сверху, на тех же полях.
    final switcher = Wrap(
      spacing: AppSizes.kChipSpacing,
      runSpacing: AppSizes.kChipSpacing,
      children: [
        for (var i = 0; i < views.length; i++)
          PortalChoice(
            label: _label(views[i]),
            selected: views[i] == view,
            onTap: () => _select(i),
          ),
      ],
    );
    return switch (view) {
      _View.stocktakes => _stocktakes(switcher),
      _View.documents => DocumentsTab(
        key: const ValueKey('stocktake'),
        kind: 'stocktake',
        empty: t.portal.inventory.empty,
        rights: widget.stocktakeDocs!,
        header: switcher,
      ),
      _View.stockEntry => DocumentsTab(
        key: const ValueKey('stock_entry'),
        kind: 'stock_entry',
        empty: t.portal.inventory.empty,
        rights: widget.stockEntryDocs!,
        header: switcher,
      ),
    };
  }

  /// Вид «Пересчёты»: переключатель на полях страницы-списка, под ним — пересчёты
  /// (до своего шага ADHOC-56 — в прежнем виде).
  Widget _stocktakes(Widget switcher) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < AppSizes.kPortalCompactWidth;
      final page = narrow ? AppInsets.pageCompact : AppInsets.page;
      final compact =
          MediaQuery.sizeOf(context).width <
          AppSizes.kPortalCompactContentWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: page.copyWith(bottom: 0),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppSizes.kPortalListMaxWidth,
                ),
                child: SizedBox(width: double.infinity, child: switcher),
              ),
            ),
          ),
          AppBoxes.kHeight16,
          Expanded(
            child: StocktakesView(
              padding: compact ? AppInsets.all16 : AppInsets.all32,
              canManage: widget.canManage,
            ),
          ),
        ],
      );
    },
  );
}
