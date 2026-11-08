import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../domain/picking/picking_order.dart';
import 'picking_labels.dart';
import 'picking_line_tile.dart';

TextStyle get _muted =>
    RegularTextStyles().regularInter13.copyWith(color: AppColors.kTextMuted);

/// Шапка заказа в окне деталей (P8-03): статус, номера 1С, клиент, кто держит, собрал и
/// отгрузил — каждый факт своей строкой.
class PickingOrderHeader extends StatelessWidget {
  const PickingOrderHeader({super.key, required this.order});

  final PickingOrderSummary order;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final o = order;
    final orderDate = o.orderDate;
    final taken = o.takenAt;
    final picked = o.pickedAt;
    final shipped = o.shippedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PickingStatusBadges(order: o),
        AppBoxes.kHeight8,
        Text(p.order(number: o.orderNumber), style: _muted),
        if (orderDate != null)
          Text(p.orderDate(date: fullDate(orderDate)), style: _muted),
        Text(p.invoice(number: o.invoiceNumber), style: _muted),
        Text(p.registryDate(date: fullDate(o.registryDate)), style: _muted),
        if (o.client.isNotEmpty) Text(p.client(name: o.client), style: _muted),
        if (o.direction.isNotEmpty)
          Text(p.direction(name: o.direction), style: _muted),
        if (o.address.isNotEmpty)
          Text(p.address(name: o.address), style: _muted),
        if (o.assigneeName.isNotEmpty)
          Text(p.assignee(name: o.assigneeName), style: _muted),
        if (o.assigneeName.isNotEmpty && taken != null)
          Text(p.takenAt(time: fullDateTime(taken)), style: _muted),
        if (o.pickedByName.isNotEmpty && picked != null)
          Text(
            p.picked(name: o.pickedByName, time: fullDateTime(picked)),
            style: _muted,
          ),
        if (shipped != null)
          Text(p.shipped(time: fullDateTime(shipped)), style: _muted),
      ],
    );
  }
}

/// Строки заказа в рамке, разделённые линиями.
class PickingLinesSection extends StatelessWidget {
  const PickingLinesSection({super.key, required this.lines});

  final List<PickingOrderLine> lines;

  @override
  Widget build(BuildContext context) => _Section(
    title: t.portal.picking.sectionLines,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.kBorder),
        borderRadius: AppBorders.kCircular8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.kDivider),
            PickingLineTile(line: lines[i]),
          ],
        ],
      ),
    ),
  );
}

/// Короба отгрузки заказа: «Короб 1», отгруженный — со временем отгрузки.
class PickingBoxesSection extends StatelessWidget {
  const PickingBoxesSection({super.key, required this.boxes});

  final List<PickingBoxInfo> boxes;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    return _Section(
      title: p.sectionBoxes,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (boxes.isEmpty) Text(p.noBoxes, style: _muted),
          for (final b in boxes)
            Text(
              b.shippedAt == null
                  ? p.box(seq: b.seq)
                  : p.boxShipped(seq: b.seq, time: fullDateTime(b.shippedAt!)),
              style: _muted,
            ),
        ],
      ),
    );
  }
}

/// Правки реестра повторными загрузками: время и что поменялось.
class PickingChangesSection extends StatelessWidget {
  const PickingChangesSection({super.key, required this.changes});

  final List<PickingOrderChange> changes;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    return _Section(
      title: p.sectionChanges,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changes.isEmpty) Text(p.noChanges, style: _muted),
          for (final c in changes)
            Text(
              p.changeAt(
                time: fullDateTime(c.at),
                text: pickingChangeText(
                  kind: c.kind,
                  goodCode: c.goodCode,
                  goodName: c.goodName,
                  oldQty: c.oldQty,
                  newQty: c.newQty,
                ),
              ),
              style: _muted,
            ),
        ],
      ),
    );
  }
}

/// Журнал событий заказа (P9-07): кто брал, отказывался, был снят, собрал и отгрузил.
class PickingEventsSection extends StatelessWidget {
  const PickingEventsSection({super.key, required this.events});

  final List<PickingOrderEvent> events;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    return _Section(
      title: p.sectionEvents,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (events.isEmpty) Text(p.noEvents, style: _muted),
          for (final e in events)
            Text(
              p.changeAt(time: fullDateTime(e.at), text: pickingEventText(e)),
              style: _muted,
            ),
        ],
      ),
    );
  }
}

/// Раздел окна: заголовок и содержимое под ним.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: SemiboldTextStyles().semiboldInter13.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      AppBoxes.kHeight8,
      child,
    ],
  );
}
