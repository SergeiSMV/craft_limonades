import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../domain/picking/picking_order.dart';
import '../ui/portal_card.dart';
import 'picking_labels.dart';
import 'picking_order_card.dart';

/// Заказы даты таблицей (P8-03): «Заказ» (номер сборки, заказ и накладная 1С), клиент
/// (направление и адрес под ним), статус с пометками, исполнитель, план и факт. Нажатие на
/// строку открывает окно деталей.
///
/// Уже [AppSizes.kPickingTableMinWidth] (телефон) - строки [PickingOrderCard] в той же
/// карточке, как у документов.
class PickingOrderTable extends StatelessWidget {
  const PickingOrderTable({
    super.key,
    required this.orders,
    required this.onOpen,
  });

  final List<PickingOrderSummary> orders;
  final ValueChanged<PickingOrderSummary> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < AppSizes.kPickingTableMinWidth) {
        return PortalCard(
          children: [
            for (final o in orders)
              PickingOrderCard(order: o, onTap: () => onOpen(o)),
          ],
        );
      }
      return PortalCard(
        children: [
          Padding(
            padding: AppInsets.h8,
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: const {
                0: MaxColumnWidth(
                  FixedColumnWidth(AppSizes.kColPickingOrderMin),
                  FlexColumnWidth(AppSizes.kColPickingOrder),
                ),
                1: MaxColumnWidth(
                  FixedColumnWidth(AppSizes.kColPickingClientMin),
                  FlexColumnWidth(AppSizes.kColPickingClient),
                ),
                2: IntrinsicColumnWidth(),
                3: IntrinsicColumnWidth(),
                4: IntrinsicColumnWidth(),
              },
              children: [
                _header(),
                for (var i = 0; i < orders.length; i++)
                  _row(orders[i], last: i == orders.length - 1),
              ],
            ),
          ),
        ],
      );
    },
  );

  /// Шапка: мелкие приглушённые подписи, линия под ней.
  TableRow _header() {
    final p = t.portal.picking;
    Widget th(String text) => Padding(
      padding: AppInsets.tableHeadCell,
      child: Text(
        text,
        style: SemiboldTextStyles().semiboldInter12.copyWith(
          color: AppColors.kTextMuted,
        ),
      ),
    );
    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.kDivider)),
      ),
      children: [
        th(p.colOrder),
        th(p.colClient),
        th(p.colStatus),
        th(p.colAssignee),
        th(p.colQty),
      ],
    );
  }

  /// Строка заказа; вся строка - нажатие. Удалённый в 1С приглушён: собирать его не будут.
  TableRow _row(PickingOrderSummary o, {required bool last}) {
    final p = t.portal.picking;
    final taken = o.takenAt;
    Widget tap(Widget child) => TableRowInkWell(
      onTap: () => onOpen(o),
      child: Padding(padding: AppInsets.tableCell, child: child),
    );
    return TableRow(
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.kDivider)),
            ),
      children: [
        tap(
          _TwoLines(
            main: docNumber(DocKind.picking, o.number),
            sub: [
              p.order(number: o.orderNumber),
              p.invoice(number: o.invoiceNumber),
            ],
            dim: o.deleted,
          ),
        ),
        tap(
          _TwoLines(
            main: o.client,
            sub: [
              if (o.direction.isNotEmpty) o.direction,
              if (o.address.isNotEmpty) o.address,
            ],
            dim: o.deleted,
          ),
        ),
        tap(PickingStatusBadges(order: o)),
        tap(
          _TwoLines(
            main: o.assigneeName.isNotEmpty ? o.assigneeName : o.pickedByName,
            sub: [
              if (o.assigneeName.isNotEmpty && taken != null)
                p.takenAt(time: shortDateTime(taken)),
            ],
            dim: true,
          ),
        ),
        tap(
          _TwoLines(
            main: p.qtyPlanFact(fact: fmtQty(o.factQty), plan: o.planQty),
            sub: [p.boxes(count: o.boxes)],
            dim: true,
            numeric: true,
          ),
        ),
      ],
    );
  }
}

/// Ячейка: основная строка и пояснения под ней. [dim] - основная обычным шрифтом.
class _TwoLines extends StatelessWidget {
  const _TwoLines({
    required this.main,
    required this.sub,
    this.dim = false,
    this.numeric = false,
  });

  final String main;
  final List<String> sub;
  final bool dim;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    // Цифры одинаковой ширины: план и факт стоят ровно друг под другом.
    final figures = numeric ? const [FontFeature.tabularFigures()] : null;
    final mainStyle = dim
        ? RegularTextStyles().regularInter13.copyWith(
            color: AppColors.kTextSecondary,
            fontFeatures: figures,
          )
        : SemiboldTextStyles().semiboldInter13.copyWith(
            color: AppColors.kTextMain,
          );
    final subStyle = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
      fontFeatures: figures,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (main.isNotEmpty) Text(main, style: mainStyle),
        for (final s in sub) Text(s, style: subStyle),
      ],
    );
  }
}
