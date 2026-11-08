import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../domain/picking/picking_order.dart';
import 'picking_labels.dart';

/// Заказ строкой для узкого экрана (P8-03): то же, что строка таблицы, но каждый факт своей
/// строкой с подписью. Нажатие открывает окно деталей.
class PickingOrderCard extends StatelessWidget {
  const PickingOrderCard({super.key, required this.order, required this.onTap});

  final PickingOrderSummary order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final o = order;
    final taken = o.takenAt;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextSecondary,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: AppInsets.cardRow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              docNumber(DocKind.picking, o.number),
              style: SemiboldTextStyles().semiboldInter13.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            AppBoxes.kHeight4,
            PickingStatusBadges(order: o),
            AppBoxes.kHeight4,
            Text(p.order(number: o.orderNumber), style: muted),
            Text(p.invoice(number: o.invoiceNumber), style: muted),
            if (o.client.isNotEmpty)
              Text(p.client(name: o.client), style: muted),
            if (o.direction.isNotEmpty)
              Text(p.direction(name: o.direction), style: muted),
            if (o.assigneeName.isNotEmpty)
              Text(p.assignee(name: o.assigneeName), style: muted),
            if (o.assigneeName.isNotEmpty && taken != null)
              Text(p.takenAt(time: shortDateTime(taken)), style: muted),
            if (o.pickedByName.isNotEmpty && o.assigneeName.isEmpty)
              Text(p.pickedBy(name: o.pickedByName), style: muted),
            Text(
              p.qtyLine(
                value: p.qtyPlanFact(fact: fmtQty(o.factQty), plan: o.planQty),
              ),
              style: muted,
            ),
            Text(p.boxes(count: o.boxes), style: muted),
          ],
        ),
      ),
    );
  }
}
