import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../domain/picking/picking_order.dart';
import '../ui/portal_badge.dart';

/// Статус заказа сборки для оператора.
String pickingStatusLabel(PickingStatus s) {
  final p = t.portal.picking;
  return switch (s) {
    PickingStatus.newOrder => p.statusNew,
    PickingStatus.inProgress => p.statusInProgress,
    PickingStatus.picked => p.statusPicked,
    PickingStatus.shipped => p.statusShipped,
  };
}

/// Правка реестра одной строкой: что и с каким количеством (P8-02 — предпросмотр, P8-03 —
/// окно деталей).
String pickingChangeText({
  required String kind,
  required String goodCode,
  required String goodName,
  required int? oldQty,
  required int? newQty,
}) {
  final p = t.portal.picking;
  return switch (kind) {
    'line_added' => p.changeAdded(
      code: goodCode,
      name: goodName,
      qty: newQty ?? 0,
    ),
    'line_removed' => p.changeRemoved(
      code: goodCode,
      name: goodName,
      qty: oldQty ?? 0,
    ),
    'qty_changed' => p.changeQty(
      code: goodCode,
      name: goodName,
      old: oldQty ?? 0,
      qty: newQty ?? 0,
    ),
    'order_deleted' => p.changeOrderDeleted,
    _ => p.changeOrderRestored,
  };
}

/// Событие журнала заказа одной строкой (P9-07): кто и что сделал.
String pickingEventText(PickingOrderEvent e) {
  final p = t.portal.picking;
  final boxes = e.boxes ?? 0;
  final qty = fmtQty(e.qty ?? 0);
  return switch (e.kind) {
    'taken' => p.eventTaken(name: e.userName),
    'taken_over' => p.eventTakenOver(name: e.userName, prev: e.prevName),
    'released' => p.eventReleased(name: e.userName),
    'released_by_lead' => p.eventReleasedByLead(
      name: e.userName,
      prev: e.prevName,
    ),
    'completed' => p.eventCompleted(name: e.userName, boxes: boxes, qty: qty),
    'reopened' => p.eventReopened(name: e.userName, prev: e.prevName),
    _ => p.eventShipped(name: e.userName, boxes: boxes, qty: qty),
  };
}

/// Статус WMS и пометки заказа отметками: «В работе», «Собран частично», «Удалён в 1С»…
///
/// Цвет — по смыслу: в работе — справка, собран и отгружен — успех, частично и нераспознанное
/// — внимание, удалён и изменён после отгрузки — критично.
class PickingStatusBadges extends StatelessWidget {
  const PickingStatusBadges({super.key, required this.order});

  final PickingOrderSummary order;

  @override
  Widget build(BuildContext context) {
    final p = t.portal.picking;
    final o = order;
    final tone = switch (o.status) {
      PickingStatus.newOrder => PortalBadgeTone.neutral,
      PickingStatus.inProgress => PortalBadgeTone.info,
      PickingStatus.picked || PickingStatus.shipped => PortalBadgeTone.success,
    };
    return Wrap(
      spacing: AppSizes.kChipSpacing,
      runSpacing: AppSizes.kChipSpacing,
      children: [
        PortalBadge(pickingStatusLabel(o.status), tone: tone),
        if (o.isPartial)
          PortalBadge(p.badgePartial, tone: PortalBadgeTone.warning),
        if (o.hasUnknown)
          PortalBadge(p.badgeUnknown, tone: PortalBadgeTone.warning),
        if (o.deleted)
          PortalBadge(p.badgeDeleted, tone: PortalBadgeTone.critical),
        if (o.changedAfterShipment)
          PortalBadge(
            p.badgeChangedAfterShipment,
            tone: PortalBadgeTone.critical,
          ),
      ],
    );
  }
}
