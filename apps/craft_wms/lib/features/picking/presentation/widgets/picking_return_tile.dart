import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/widgets/neumorphic_line_tile.dart';
import '../../domain/picking_return.dart';

/// Позиция возврата на места (P9-07-1): товар, партия, сколько вернуть, откуда брали - каждый
/// факт своей строкой. Позиция из короба, который ещё не отсканирован, - серая; выбранная - с
/// галочкой справа.
class PickingReturnTile extends StatelessWidget {
  const PickingReturnTile({
    super.key,
    required this.pick,
    required this.available,
    required this.pending,
    required this.active,
    required this.selected,
    required this.onTap,
  });

  final PickingReturnPick pick;

  /// Сколько можно вернуть из позиции сейчас.
  final double available;

  /// Сколько по ней ушло в очередь без связи.
  final double pending;
  final bool active;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = pick.sourceLoadUnitId == null
        ? t.pickingReturn.fromCell(cell: pick.sourceCell)
        : t.pickingReturn.fromBox(
            box: boxCode(pick.sourceLoadUnitId!),
            cell: pick.sourceCell,
          );
    final lines = <String>[
      t.picking.batch(date: batchDate(pick.productionDate)),
      t.pickingReturn.lineLeft(qty: fmtQty(available), uom: pick.uom),
      if (pick.moved)
        t.pickingReturn.pickQty(qty: fmtQty(pick.qty), uom: pick.uom),
      source,
      if (pending > 0)
        t.pickingReturn.pending(qty: fmtQty(pending), uom: pick.uom),
    ];
    final tile = NeumorphicLineTile(
      title: pick.goodName,
      subtitle: lines.join('\n'),
      trailing: selected ? t.supplierReturn.checkedMark : null,
      onTap: onTap,
    );
    return active
        ? tile
        : Opacity(opacity: AppSizes.kInactiveOpacity, child: tile);
  }
}
