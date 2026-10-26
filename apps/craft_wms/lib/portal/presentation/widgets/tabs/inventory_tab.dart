import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../common/portal_filter_chip.dart';
import '../stocktake/stocktakes_view.dart';
import 'documents_tab.dart';

/// Вкладка «Инвентаризация» (P10-05): пересчёты склада, их документы «Инвентаризация» для 1С
/// и документы «Ввода остатков» (P-FS-09). Три вида — переключателем сверху: все они про
/// приведение учёта к полке, а документ «Инвентаризация» рождается закрытием пересчёта.
class InventoryTab extends StatefulWidget {
  const InventoryTab({super.key});

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  int _view = 0;

  /// Сменить вид.
  void _select(int view) => setState(() => _view = view);

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < AppSizes.kPortalCompactContentWidth;
    final pad = compact ? AppInsets.all16 : AppInsets.all32;
    final labels = [
      t.portal.stocktake.viewStocktakes,
      t.portal.stocktake.viewDocuments,
      t.portal.stocktake.viewStockEntry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: pad.copyWith(bottom: 0),
          child: Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (var i = 0; i < labels.length; i++)
                PortalFilterChip(
                  label: labels[i],
                  selected: _view == i,
                  onTap: () => _select(i),
                ),
            ],
          ),
        ),
        AppBoxes.kHeight16,
        Expanded(
          child: switch (_view) {
            0 => StocktakesView(padding: pad),
            1 => DocumentsTab(
              key: const ValueKey('stocktake'),
              kind: 'stocktake',
              empty: t.portal.inventory.empty,
            ),
            _ => DocumentsTab(
              key: const ValueKey('stock_entry'),
              kind: 'stock_entry',
              empty: t.portal.inventory.empty,
            ),
          },
        ),
      ],
    );
  }
}
