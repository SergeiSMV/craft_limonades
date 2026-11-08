import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/box_code.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_sources.dart';
import '../../domain/picking_view.dart';

/// Подписи сборки для человека (P9-06): каждый факт - своей подписанной строкой.

/// Шапка заказа: накладная, заказ, клиент, направление, дата накладной.
List<String> orderLines({
  required String invoiceNumber,
  required String orderNumber,
  required String client,
  required String direction,
  required String registryDate,
}) {
  final p = t.picking;
  return [
    if (invoiceNumber.isNotEmpty) p.invoice(number: invoiceNumber),
    if (orderNumber.isNotEmpty) p.order(number: orderNumber),
    if (client.isNotEmpty) p.client(name: client),
    if (direction.isNotEmpty) p.direction(name: direction),
    p.date(date: batchDate(transportDate(registryDate))),
  ];
}

/// Строка списка «СБОРКА».
List<String> listItemLines(PickingListItem o) => [
  ...orderLines(
    invoiceNumber: o.invoiceNumber,
    orderNumber: o.orderNumber,
    client: o.client,
    direction: o.direction,
    registryDate: o.registryDate,
  ),
  t.picking.lines(count: o.lines),
  if (o.mine)
    t.picking.statusMine
  else if (o.busy)
    t.picking.statusBusy(name: o.assigneeName)
  else if (o.status == PickingStatus.inProgress)
    t.picking.statusStale,
  if (o.hasUnknown) t.picking.hasUnknown,
];

/// Откуда взять по подбору: ячейка россыпью или короб в ячейке.
String takeLine(PickingTake take, String uom) => take.fromBox
    ? t.picking.takeBox(
        box: boxCode(take.loadUnitId!),
        cell: take.cellAddress,
        qty: fmtQty(take.qty),
        uom: uom,
      )
    : t.picking.takeCell(
        cell: take.cellAddress,
        qty: fmtQty(take.qty),
        uom: uom,
      );

/// Строка заказа: собрано, партия и ячейка реестра, подсказка, отметки.
List<String> lineLines(PickingOrderView view, PickingLine l) {
  final p = t.picking;
  final sg = l.suggestion;
  return [
    p.taken(taken: fmtQty(view.taken(l)), plan: '${l.planQty}', uom: l.uom),
    if (l.batchDate != null)
      p.batch(date: batchDate(transportDate(l.batchDate!))),
    if (l.registryCell.isNotEmpty) p.registryCell(cell: l.registryCell),
    if (!view.done(l) && sg != null) ...[
      for (final take in sg.takes) takeLine(take, l.uom),
      if (sg.batchSubstituted) p.batchSubstituted,
      if (sg.cellSubstituted) p.cellSubstituted,
      if (sg.short > 0) p.short(qty: fmtQty(sg.short), uom: l.uom),
    ],
    if (l.czMarked) p.marked,
    if (l.shortage) p.shortageMark,
  ];
}

/// Пик: откуда, партия, сколько, в какой короб, марки.
List<String> pickLines(PickingOrderView view, ViewPick vp, String uom) {
  final p = t.picking;
  final pick = vp.pick;
  final seq = view.boxSeq(pick.boxId);
  return [
    if (pick.loadUnitId != null)
      p.pickFromBox(box: boxCode(pick.loadUnitId!), cell: pick.cellAddress)
    else
      p.pickFromCell(cell: pick.cellAddress),
    p.batch(date: batchDate(pick.productionDate)),
    p.pickQty(qty: fmtQty(pick.qty), uom: uom),
    if (seq != null) p.pickBox(seq: seq),
    if (pick.marks.isNotEmpty) p.pickMarks(count: pick.marks.length),
    if (vp.pending) p.pickPending,
    if (vp.returnPending) p.pickReturning,
  ];
}
