import 'package:freezed_annotation/freezed_annotation.dart';

import 'picking_models.dart';

part 'picking_card.freezed.dart';
part 'picking_card.g.dart';

/// Карточка заказа сборки на ТСД (ADHOC-62): то же, что окно деталей портала, только чтение.
/// Открывается из «Завершённых»: шапка, кто собрал и отгрузил, позиции план/факт по партиям,
/// короба с составом, журнал заказа. Ответ `GET /picking/orders/{id}/card`.
@freezed
abstract class PickingCard with _$PickingCard {
  const factory PickingCard({
    required String id,
    required int number,
    @JsonKey(name: 'registry_date') required String registryDate,
    @JsonKey(name: 'invoice_number') @Default('') String invoiceNumber,
    @JsonKey(name: 'order_number') @Default('') String orderNumber,
    @Default('') String direction,
    @Default('') String client,
    @Default('') String address,
    required String status,
    @JsonKey(name: 'is_partial') @Default(false) bool isPartial,
    @Default(false) bool deleted,
    @JsonKey(name: 'changed_after_shipment')
    @Default(false)
    bool changedAfterShipment,
    @JsonKey(name: 'picked_by_name') @Default('') String pickedByName,
    @JsonKey(name: 'picked_at') DateTime? pickedAt,
    @JsonKey(name: 'shipped_at') DateTime? shippedAt,
    @JsonKey(name: 'plan_qty') @Default(0) int planQty,
    @JsonKey(name: 'fact_qty') @QtyConverter() @Default(0) double factQty,
    @Default(<PickingCardLine>[]) List<PickingCardLine> items,
    @JsonKey(name: 'box_list')
    @Default(<PickingCardBox>[])
    List<PickingCardBox> boxList,
    @Default(<PickingCardEvent>[]) List<PickingCardEvent> events,
  }) = _PickingCard;

  const PickingCard._();

  /// Отгружен.
  bool get shipped => status == PickingStatus.shipped;

  /// Кто отгрузил - последнее событие `shipped` журнала; пусто - не отгружен или журнала нет.
  String get shippedBy {
    for (final e in events.reversed) {
      if (e.kind == PickingCardEvent.kindShipped) return e.userName;
    }
    return '';
  }

  /// Состав короба [seq]: пики, перенесённые в него, вместе со своей строкой. Возвращённые на
  /// место сервер не отдаёт - состав совпадает с тем, что уехало.
  List<({PickingCardLine line, PickingCardFact fact})> boxContent(int seq) => [
    for (final l in items)
      for (final f in l.facts)
        if (f.inBox && f.boxSeq == seq) (line: l, fact: f),
  ];

  factory PickingCard.fromJson(Map<String, dynamic> json) =>
      _$PickingCardFromJson(json);
}

/// Строка плана и факт по ней: партия реестра (`null` - любая), «не хватает», убрана реестром.
@freezed
abstract class PickingCardLine with _$PickingCardLine {
  const factory PickingCardLine({
    required String id,
    @JsonKey(name: 'line_no') @Default(0) int lineNo,
    @JsonKey(name: 'good_code') @Default('') String goodCode,
    @JsonKey(name: 'good_name') @Default('') String goodName,
    @Default('') String uom,
    @JsonKey(name: 'cz_marked') @Default(false) bool czMarked,
    @JsonKey(name: 'batch_date') String? batchDate,
    @JsonKey(name: 'registry_cell') @Default('') String registryCell,
    @JsonKey(name: 'cell_address') @Default('') String cellAddress,
    @JsonKey(name: 'plan_qty') @Default(0) int planQty,
    @JsonKey(name: 'fact_qty') @QtyConverter() @Default(0) double factQty,
    @Default(false) bool removed,
    @Default(false) bool shortage,
    @Default(<PickingCardFact>[]) List<PickingCardFact> facts,
  }) = _PickingCardLine;

  const PickingCardLine._();

  /// Сколько не собрано против плана; у убранной строки - ноль.
  double get missing => removed || factQty >= planQty ? 0 : planQty - factQty;

  /// Все марки строки - по пикам.
  List<String> get marks => [for (final f in facts) ...f.marks];

  /// Факт по партиям в порядке первого пика: партия (ГГГГ-ММ-ДД) и сколько.
  List<({String date, double qty})> get byBatch {
    final order = <String>[];
    final sums = <String, double>{};
    for (final f in facts) {
      if (!sums.containsKey(f.batchDate)) order.add(f.batchDate);
      sums[f.batchDate] = (sums[f.batchDate] ?? 0) + f.qty;
    }
    return [for (final d in order) (date: d, qty: sums[d]!)];
  }

  factory PickingCardLine.fromJson(Map<String, dynamic> json) =>
      _$PickingCardLineFromJson(json);
}

/// Пик строки: партия, откуда, в какой короб, сколько, марки. `state` - `picking` («в сборке»)
/// или `moved` (в коробе отгрузки).
@freezed
abstract class PickingCardFact with _$PickingCardFact {
  const factory PickingCardFact({
    @JsonKey(name: 'batch_date') required String batchDate,
    @JsonKey(name: 'cell_address') @Default('') String cellAddress,
    @JsonKey(name: 'box_seq') @Default(0) int boxSeq,
    @QtyConverter() @Default(0) double qty,
    @Default('') String state,
    @JsonKey(name: 'picked_by') @Default('') String pickedBy,
    @JsonKey(name: 'picked_at') DateTime? pickedAt,
    @Default(<String>[]) List<String> marks,
  }) = _PickingCardFact;

  const PickingCardFact._();

  /// Товар уже в коробе отгрузки.
  bool get inBox => state == 'moved';

  factory PickingCardFact.fromJson(Map<String, dynamic> json) =>
      _$PickingCardFactFromJson(json);
}

/// Короб отгрузки заказа: «короб N», [shippedAt] - отгружен.
@freezed
abstract class PickingCardBox with _$PickingCardBox {
  const factory PickingCardBox({
    required int seq,
    @JsonKey(name: 'shipped_at') DateTime? shippedAt,
  }) = _PickingCardBox;

  factory PickingCardBox.fromJson(Map<String, dynamic> json) =>
      _$PickingCardBoxFromJson(json);
}

/// Событие журнала заказа (P9-07): вид, кто, у кого перехватили или с кого сняли; у завершения,
/// возврата и отгрузки - короба и штуки.
@freezed
abstract class PickingCardEvent with _$PickingCardEvent {
  const factory PickingCardEvent({
    required String kind,
    @JsonKey(name: 'user_name') @Default('') String userName,
    @JsonKey(name: 'prev_name') @Default('') String prevName,
    int? boxes,
    @QtyConverter() @Default(0) double qty,
    required DateTime at,
  }) = _PickingCardEvent;

  static const kindShipped = 'shipped';

  factory PickingCardEvent.fromJson(Map<String, dynamic> json) =>
      _$PickingCardEventFromJson(json);
}
