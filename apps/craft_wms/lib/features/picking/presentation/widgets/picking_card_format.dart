import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../domain/picking_card.dart';
import '../../domain/picking_sources.dart';
import 'picking_format.dart';

/// Подписи карточки заказа (ADHOC-62): каждый факт - своей подписанной строкой.

/// Дата из ответа сервера (ГГГГ-ММ-ДД) в привычную ДД.ММ.ГГГГ.
String _date(String iso) => batchDate(transportDate(iso));

/// Шапка: номера 1С, клиент, адрес, статус, пометки 1С, кто собрал и отгрузил, итог.
List<String> cardHeaderLines(PickingCard c) {
  final p = t.picking;
  final pickedAt = c.pickedAt;
  final shippedAt = c.shippedAt;
  final shippedBy = c.shippedBy;
  return [
    ...orderLines(
      invoiceNumber: c.invoiceNumber,
      orderNumber: c.orderNumber,
      client: c.client,
      direction: c.direction,
      registryDate: c.registryDate,
    ),
    if (c.address.isNotEmpty) p.labelAddress(address: c.address),
    if (c.shipped)
      c.isPartial ? p.statusShippedPartial : p.statusShipped
    else
      c.isPartial ? p.statusPartial : p.statusPicked,
    if (c.deleted) p.cardDeleted,
    if (c.changedAfterShipment) p.cardChangedAfterShipment,
    if (c.pickedByName.isNotEmpty) p.cardPickedBy(name: c.pickedByName),
    if (pickedAt != null) p.cardPickedAt(time: fullDateTime(pickedAt)),
    if (shippedBy.isNotEmpty) p.cardShippedBy(name: shippedBy),
    if (shippedAt != null) p.cardShippedAt(time: fullDateTime(shippedAt)),
    p.cardTotal(fact: fmtQty(c.factQty), plan: '${c.planQty}'),
  ];
}

/// Позиция: план и партия реестра, собрано всего и по партиям, марки.
List<String> cardLineLines(PickingCardLine l) {
  final p = t.picking;
  final batch = l.batchDate;
  return [
    p.cardPlan(qty: '${l.planQty}', uom: l.uom),
    batch == null ? p.cardPlanNoBatch : p.cardPlanBatch(date: _date(batch)),
    if (l.registryCell.isNotEmpty) p.registryCell(cell: l.registryCell),
    p.cardFact(qty: fmtQty(l.factQty), uom: l.uom),
    for (final b in l.byBatch)
      p.cardFactBatch(date: _date(b.date), qty: fmtQty(b.qty), uom: l.uom),
    if (l.marks.isNotEmpty) p.cardMarks(count: l.marks.length),
  ];
}

/// Отметка позиции под подписью: убрана реестром или сколько не хватило; `null` - собрано.
String? cardLineNote(PickingCardLine l) {
  final p = t.picking;
  if (l.removed) return p.cardRemoved;
  if (l.missing > 0) {
    return p.cardMissing(qty: fmtQty(l.missing), uom: l.uom);
  }
  if (l.shortage) return p.shortageMark;
  return null;
}

/// Состав короба: товар своей строкой, под ним партии с количеством; отгружен - когда.
List<String> cardBoxLines(PickingCard c, PickingCardBox box) {
  final p = t.picking;
  final content = c.boxContent(box.seq);
  final shippedAt = box.shippedAt;
  // Пики одной строки в коробе - подряд под её товаром, партии сведены.
  final byLine = <String, Map<String, double>>{};
  final lines = <String, PickingCardLine>{};
  for (final e in content) {
    lines[e.line.id] = e.line;
    final batches = byLine.putIfAbsent(e.line.id, () => <String, double>{});
    batches[e.fact.batchDate] = (batches[e.fact.batchDate] ?? 0) + e.fact.qty;
  }
  return [
    if (content.isEmpty) p.cardBoxEmpty,
    for (final id in byLine.keys) ...[
      p.cardBoxGood(code: lines[id]!.goodCode, name: lines[id]!.goodName),
      for (final b in byLine[id]!.entries)
        p.cardFactBatch(
          date: _date(b.key),
          qty: fmtQty(b.value),
          uom: lines[id]!.uom,
        ),
    ],
    if (shippedAt != null) p.cardShippedAt(time: fullDateTime(shippedAt)),
  ];
}

/// Событие журнала одной строкой: время и кто что сделал.
String cardEventLine(PickingCardEvent e) {
  final p = t.picking;
  final boxes = e.boxes ?? 0;
  final qty = fmtQty(e.qty);
  final text = switch (e.kind) {
    'taken' => p.eventTaken(name: e.userName),
    'taken_over' => p.eventTakenOver(name: e.userName, prev: e.prevName),
    'released' => p.eventReleased(name: e.userName),
    'released_by_lead' => p.eventReleasedByLead(
      name: e.userName,
      prev: e.prevName,
    ),
    'completed' => p.eventCompleted(name: e.userName, boxes: boxes, qty: qty),
    'reopened' => p.eventReopened(name: e.userName, prev: e.prevName),
    'returned' => p.eventReturned(name: e.userName, qty: qty),
    _ => p.eventShipped(name: e.userName, boxes: boxes, qty: qty),
  };
  return p.eventAt(time: fullDateTime(e.at), text: text);
}
