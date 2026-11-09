import 'package:freezed_annotation/freezed_annotation.dart';

import 'picking_models.dart';

part 'picking_shipment.freezed.dart';
part 'picking_shipment.g.dart';

/// Собранный заказ для ярлыков и отгрузки (P9-07): шапка реестра, короба «N из M» и итог.
///
/// [boxes] - живые короба по номеру: пустые «Завершить сборку» убрала, остальные
/// перенумеровала 1…M, поэтому M - это `boxes.length`.
@freezed
abstract class PickingShipment with _$PickingShipment {
  const factory PickingShipment({
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
    @QtyConverter() @Default(0) double qty,

    /// Сколько ещё вернуть на места после правки реестра (P9-07-1): пока не ноль, отгрузка
    /// закрыта.
    @JsonKey(name: 'return_left') @QtyConverter() @Default(0) double returnLeft,
    @Default(<PickingShipmentBox>[]) List<PickingShipmentBox> boxes,
  }) = _PickingShipment;

  const PickingShipment._();

  /// Заказ отгружен.
  bool get shipped => status == PickingStatus.shipped;

  /// Короба, чей ярлык ещё ни разу не печатали: их печать не требует права повтора.
  List<PickingShipmentBox> get unprinted =>
      boxes.where((b) => b.labelsPrinted == 0).toList();

  factory PickingShipment.fromJson(Map<String, dynamic> json) =>
      _$PickingShipmentFromJson(json);
}

/// Короб отгрузки: номер, штук, сколько раз печатали ярлык, отгружен ли.
@freezed
abstract class PickingShipmentBox with _$PickingShipmentBox {
  const factory PickingShipmentBox({
    @JsonKey(name: 'load_unit_id') required String loadUnitId,
    required int seq,
    @QtyConverter() @Default(0) double qty,
    @JsonKey(name: 'labels_printed') @Default(0) int labelsPrinted,
    @Default(false) bool shipped,
  }) = _PickingShipmentBox;

  factory PickingShipmentBox.fromJson(Map<String, dynamic> json) =>
      _$PickingShipmentBoxFromJson(json);
}
