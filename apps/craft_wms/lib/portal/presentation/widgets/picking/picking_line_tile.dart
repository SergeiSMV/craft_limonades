import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../domain/picking/picking_order.dart';

/// Строка заказа в окне деталей (P8-03): обе стороны — что в реестре и что сделано на складе,
/// каждый факт своей строкой.
///
/// Реестр: товар, план, партия, ячейка. Склад: факт (сколько ещё «в сборке» — в скобках), факт
/// по партиям, «не хватает». Марки ЧЗ раскрываются нажатием: у маркируемой строки их сотни.
/// Убранная реестром строка приглушена.
class PickingLineTile extends StatefulWidget {
  const PickingLineTile({super.key, required this.line});

  final PickingOrderLine line;

  @override
  State<PickingLineTile> createState() => _PickingLineTileState();
}

class _PickingLineTileState extends State<PickingLineTile> {
  bool _marksOpen = false;

  /// Раскрыть или свернуть марки.
  void _toggleMarks() => setState(() => _marksOpen = !_marksOpen);

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final l = widget.line;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final warn = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kBadgeWarningText,
    );
    final batch = l.batchDate;
    final inPicking = l.facts
        .where((f) => !f.inBox)
        .fold<double>(0, (s, f) => s + f.qty);
    final marks = l.marks;
    return Opacity(
      opacity: l.removed ? AppSizes.kInactiveOpacity : 1,
      child: Padding(
        padding: AppInsets.all12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.lineGood(code: l.goodCode, name: l.goodName),
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            if (l.removed) Text(p.lineRemoved, style: warn),
            Text(
              p.linePlan(qty: l.planQty, uom: l.uom),
              style: muted,
            ),
            Text(
              batch == null
                  ? p.linePlanNoBatch
                  : p.linePlanBatch(date: fullDate(batch)),
              style: muted,
            ),
            if (l.registryCell.isNotEmpty)
              Text(
                l.cellAddress.isNotEmpty
                    ? p.lineCell(cell: l.cellAddress)
                    : p.lineCellMissing(cell: l.registryCell),
                style: l.cellAddress.isNotEmpty ? muted : warn,
              ),
            Text(
              inPicking > 0
                  ? p.lineFactInPicking(
                      qty: fmtQty(l.factQty),
                      uom: l.uom,
                      picking: fmtQty(inPicking),
                    )
                  : p.lineFact(qty: fmtQty(l.factQty), uom: l.uom),
              style: l.factQty < l.planQty && !l.removed ? warn : muted,
            ),
            for (final b in _byBatch(l.facts))
              Text(
                p.lineFactBatch(
                  date: fullDate(b.date),
                  qty: fmtQty(b.qty),
                  uom: l.uom,
                ),
                style: muted,
              ),
            if (l.shortage) Text(p.lineShortage, style: warn),
            if (marks.isNotEmpty)
              InkWell(
                onTap: _toggleMarks,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(p.lineMarks(count: marks.length), style: muted),
                    Icon(
                      _marksOpen ? Icons.expand_less : Icons.expand_more,
                      size: AppSizes.kIcon20,
                      color: AppColors.kTextMuted,
                    ),
                  ],
                ),
              ),
            if (_marksOpen)
              for (final m in marks) SelectableText(m, style: muted),
          ],
        ),
      ),
    );
  }

  /// Факт по партиям в порядке первого пика: «Партия 05.10.2026: 3 шт.».
  List<({DateTime date, double qty})> _byBatch(List<PickingFact> facts) {
    final order = <DateTime>[];
    final sums = <DateTime, double>{};
    for (final f in facts) {
      if (!sums.containsKey(f.batchDate)) order.add(f.batchDate);
      sums[f.batchDate] = (sums[f.batchDate] ?? 0) + f.qty;
    }
    return [for (final d in order) (date: d, qty: sums[d]!)];
  }
}
