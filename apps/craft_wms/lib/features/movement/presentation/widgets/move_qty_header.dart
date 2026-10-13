import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../domain/movement_models.dart';
import 'move_format.dart';

/// Что берут — над полем количества (P6-04): товар, партия и сколько его в источнике.
///
/// Количество вводят, видя позицию: без этого диалог показывал одно число, и по нему нельзя
/// было убедиться, что взята та партия и тот товар.
class MoveQtyHeader extends StatelessWidget {
  const MoveQtyHeader({
    super.key,
    required this.line,
    required this.available,
    required this.from,
  });

  final ContentLine line;

  /// Сколько этой партии в источнике с учётом сеанса — потолок количества.
  final double available;
  final MovePlace from;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    final qty = fmtQty(available);
    final uom = line.uom ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.goodName ?? line.goodCode ?? '',
          style: SemiboldTextStyles().semiboldInter14.copyWith(
            color: AppColors.kTextMain,
          ),
        ),
        Text(
          t.movement.qtyBatch(date: batchDate(line.productionDate)),
          style: muted,
        ),
        Text(
          from.isBox
              ? t.movement.qtyInBox(
                  code: boxCode(from.loadUnitId!),
                  qty: qty,
                  uom: uom,
                )
              : t.movement.qtyInCell(
                  cell: from.cellAddress,
                  qty: qty,
                  uom: uom,
                ),
          style: muted,
        ),
      ],
    );
  }
}
