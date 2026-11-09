import 'package:freezed_annotation/freezed_annotation.dart';

import 'picking_models.dart';

part 'picking_return.freezed.dart';
part 'picking_return.g.dart';

/// Что вернуть на места по заказу после правки реестра (P9-07-1) - ответ
/// `GET /picking/orders/{id}/return`.
///
/// [lines] - строки, по которым есть что вернуть, и сколько; [picks] - пики, из которых
/// возвращают: перенесённые в короб отгрузки ([PickingReturnPick.moved]) и, у удалённого
/// заказа, ещё «в сборке» у источника.
@freezed
abstract class PickingReturnView with _$PickingReturnView {
  const factory PickingReturnView({
    @JsonKey(name: 'order_id') required String orderId,
    required int number,
    @JsonKey(name: 'invoice_number') @Default('') String invoiceNumber,
    @JsonKey(name: 'order_number') @Default('') String orderNumber,
    @Default('') String client,
    @Default('') String status,
    @Default(false) bool deleted,
    @JsonKey(name: 'task_id') String? taskId,
    @Default(<PickingReturnLine>[]) List<PickingReturnLine> lines,
    @Default(<PickingReturnPick>[]) List<PickingReturnPick> picks,
  }) = _PickingReturnView;

  const PickingReturnView._();

  /// Сколько всего осталось вернуть.
  double get left => lines.fold(0, (sum, l) => sum + l.left);

  /// Сколько вернуть по строке [lineId].
  double lineLeft(String lineId) =>
      lines.where((l) => l.lineId == lineId).firstOrNull?.left ?? 0;

  factory PickingReturnView.fromJson(Map<String, dynamic> json) =>
      _$PickingReturnViewFromJson(json);
}

/// Строка заказа и сколько вернуть по ней.
@freezed
abstract class PickingReturnLine with _$PickingReturnLine {
  const factory PickingReturnLine({
    @JsonKey(name: 'line_id') required String lineId,
    @JsonKey(name: 'good_name') @Default('') String goodName,
    @QtyConverter() @Default(0) double left,
  }) = _PickingReturnLine;

  factory PickingReturnLine.fromJson(Map<String, dynamic> json) =>
      _$PickingReturnLineFromJson(json);
}

/// Пик, из которого возвращают: в коробе отгрузки [boxSeq] ([moved]) или ещё у источника.
@freezed
abstract class PickingReturnPick with _$PickingReturnPick {
  const factory PickingReturnPick({
    @JsonKey(name: 'pick_id') required String pickId,
    @JsonKey(name: 'line_id') required String lineId,
    @Default(false) bool moved,
    @JsonKey(name: 'box_id') required String boxId,
    @JsonKey(name: 'box_seq') @Default(0) int boxSeq,
    @JsonKey(name: 'good_id') required String goodId,
    @JsonKey(name: 'good_code') @Default('') String goodCode,
    @JsonKey(name: 'good_name') @Default('') String goodName,
    @Default('') String uom,
    @JsonKey(name: 'cz_marked') @Default(false) bool czMarked,

    /// Дата партии, DD-MM-YYYY.
    @JsonKey(name: 'production_date') @Default('') String productionDate,
    @QtyConverter() @Default(0) double qty,
    @JsonKey(name: 'source_cell_id') required String sourceCellId,
    @JsonKey(name: 'source_cell') @Default('') String sourceCell,
    @JsonKey(name: 'source_load_unit_id') String? sourceLoadUnitId,
    @Default(<String>[]) List<String> marks,
  }) = _PickingReturnPick;

  factory PickingReturnPick.fromJson(Map<String, dynamic> json) =>
      _$PickingReturnPickFromJson(json);
}
