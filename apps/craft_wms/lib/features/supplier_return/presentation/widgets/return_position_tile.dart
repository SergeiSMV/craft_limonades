import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../../tasks/presentation/widgets/common/task_format.dart';

/// Позиция возврата в сеансе отгрузки (ADHOC-31): короб или товар, построчно — состав или
/// партия и количество, ячейка, где лежит. Неактивная — серая, с подсказкой, что сканировать
/// (короб или ячейку); отмеченная — с галочкой справа.
class ReturnPositionTile extends StatelessWidget {
  const ReturnPositionTile({
    super.key,
    required this.item,
    required this.checked,
    required this.active,
    required this.onTap,
  });

  final TaskItem item;
  final bool checked;

  /// Место позиции подтверждено сканом — её можно отметить.
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (item.isBox)
        for (final c in item.contents)
          t.supplierReturn.contentLine(
            name: c.good.name,
            date: batchDate(c.productionDate),
            qty: qtyText(c.qty),
            uom: c.good.uom,
          )
      else ...[
        t.supplierReturn.batchLine(date: batchDate(item.productionDate ?? '')),
        t.supplierReturn.qtyLine(
          qty: qtyText(item.qty),
          uom: item.good?.uom ?? '',
        ),
      ],
      if (item.cell.isNotEmpty) t.supplierReturn.cellLine(cell: item.cell),
      if (!active)
        item.isBox
            ? t.supplierReturn.scanBoxOrCell(
                code: LoadUnitLabel(item.loadUnitId!).shortCodeFormatted,
                cell: item.cell,
              )
            : t.supplierReturn.scanCell(cell: item.cell),
    ];
    final tile = NeumorphicLineTile(
      title: item.isBox
          ? t.supplierReturn.box(
              code: LoadUnitLabel(item.loadUnitId!).shortCodeFormatted,
            )
          : item.good?.name ?? '',
      subtitle: lines.join('\n'),
      trailing: checked ? t.supplierReturn.checkedMark : null,
      onTap: onTap,
    );
    // Серая, но касание остаётся: оно подскажет, какую ячейку сканировать.
    return active
        ? tile
        : Opacity(opacity: AppSizes.kInactiveOpacity, child: tile);
  }
}
