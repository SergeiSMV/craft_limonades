import 'package:freezed_annotation/freezed_annotation.dart';

part 'picking_models.freezed.dart';
part 'picking_models.g.dart';

/// Сущности сборки на ТСД (P9-06). Слой `domain` фичи: ни Flutter, ни сети, ни базы.
/// JSON нужен и сети, и слепку заказа на терминале: открытый заказ собирается без связи.

/// Статус заказа сборки WMS - как на сервере.
abstract final class PickingStatus {
  static const fresh = 'new';
  static const inProgress = 'in_progress';
  static const picked = 'picked';
  static const shipped = 'shipped';
}

/// Количество с сервера приходит строкой (decimal) - число для терминала.
class QtyConverter implements JsonConverter<double, Object?> {
  const QtyConverter();

  @override
  double fromJson(Object? json) => double.tryParse('$json') ?? 0;

  @override
  Object? toJson(double object) => object;
}

/// Заказ в списке «СБОРКА»: несобранный, любой даты.
@freezed
abstract class PickingListItem with _$PickingListItem {
  const factory PickingListItem({
    required String id,
    required int number,
    @JsonKey(name: 'registry_date') required String registryDate,
    @JsonKey(name: 'invoice_number') @Default('') String invoiceNumber,
    @JsonKey(name: 'order_number') @Default('') String orderNumber,
    @Default('') String direction,
    @Default('') String client,
    @Default('') String address,
    required String status,
    @JsonKey(name: 'has_unknown') @Default(false) bool hasUnknown,
    @Default(0) int lines,
    @Default(false) bool mine,
    @Default(false) bool busy,
    @JsonKey(name: 'assignee_name') @Default('') String assigneeName,

    /// У собранного: «собран частично» и сколько коробов (P9-07).
    @JsonKey(name: 'is_partial') @Default(false) bool isPartial,
    @Default(0) int boxes,
  }) = _PickingListItem;

  const PickingListItem._();

  /// Собран и ждёт отгрузки.
  bool get picked => status == PickingStatus.picked;

  factory PickingListItem.fromJson(Map<String, dynamic> json) =>
      _$PickingListItemFromJson(json);
}

/// Откуда взять часть строки по подбору сервера: россыпь ячейки или короб хранения.
@freezed
abstract class PickingTake with _$PickingTake {
  const factory PickingTake({
    @JsonKey(name: 'cell_id') required String cellId,
    @JsonKey(name: 'cell_address') required String cellAddress,
    @JsonKey(name: 'is_floor_storage') @Default(false) bool isFloorStorage,
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    @JsonKey(name: 'internal_warehouse_id')
    @Default('')
    String internalWarehouseId,

    /// Дата партии, YYYY-MM-DD - как в ответе подбора.
    @JsonKey(name: 'batch_date') required String batchDate,
    @QtyConverter() required double qty,
  }) = _PickingTake;

  const PickingTake._();

  /// Источник - короб хранения.
  bool get fromBox => loadUnitId != null && loadUnitId!.isNotEmpty;

  factory PickingTake.fromJson(Map<String, dynamic> json) =>
      _$PickingTakeFromJson(json);
}

/// Подбор строки: что осталось взять и откуда.
@freezed
abstract class PickingSuggestion with _$PickingSuggestion {
  const factory PickingSuggestion({
    @QtyConverter() @Default(0) double remaining,
    @QtyConverter() @Default(0) double short,
    @JsonKey(name: 'batch_substituted') @Default(false) bool batchSubstituted,
    @JsonKey(name: 'cell_substituted') @Default(false) bool cellSubstituted,
    @Default(<PickingTake>[]) List<PickingTake> takes,
  }) = _PickingSuggestion;

  factory PickingSuggestion.fromJson(Map<String, dynamic> json) =>
      _$PickingSuggestionFromJson(json);
}

/// Строка плана заказа.
@freezed
abstract class PickingLine with _$PickingLine {
  const factory PickingLine({
    required String id,
    @JsonKey(name: 'line_no') @Default(0) int lineNo,
    @JsonKey(name: 'good_id') String? goodId,
    @JsonKey(name: 'good_code') @Default('') String goodCode,
    @JsonKey(name: 'good_name') @Default('') String goodName,
    @Default('') String uom,
    @JsonKey(name: 'cz_marked') @Default(false) bool czMarked,

    /// Партия реестра, YYYY-MM-DD; `null` - без партии.
    @JsonKey(name: 'batch_date') String? batchDate,
    @JsonKey(name: 'registry_cell') @Default('') String registryCell,
    @JsonKey(name: 'cell_address') @Default('') String cellAddress,
    @JsonKey(name: 'plan_qty') @Default(0) int planQty,

    /// Взято по строке на момент ответа сервера: открытые и перенесённые в короб пики.
    @QtyConverter() @Default(0) double taken,
    @Default(false) bool removed,
    @Default(false) bool shortage,
    PickingSuggestion? suggestion,
  }) = _PickingLine;

  factory PickingLine.fromJson(Map<String, dynamic> json) =>
      _$PickingLineFromJson(json);
}

/// Короб отгрузки заказа: «короб [seq]».
@freezed
abstract class PickingBox with _$PickingBox {
  const factory PickingBox({
    @JsonKey(name: 'load_unit_id') required String loadUnitId,
    required int seq,
  }) = _PickingBox;

  factory PickingBox.fromJson(Map<String, dynamic> json) =>
      _$PickingBoxFromJson(json);
}

/// Пик - взятое в короб отгрузки: строка, источник, партия, количество, марки.
///
/// [loadUnitId] - короб хранения-источник, `null` у россыпи; [cellAddress] - ячейка источника.
@freezed
abstract class PickingPick with _$PickingPick {
  const factory PickingPick({
    required String id,
    @JsonKey(name: 'line_id') required String lineId,
    @JsonKey(name: 'box_id') required String boxId,
    @JsonKey(name: 'cell_address') @Default('') String cellAddress,
    @JsonKey(name: 'load_unit_id') String? loadUnitId,

    /// Дата партии, DD-MM-YYYY - как в теле операции.
    @JsonKey(name: 'production_date') required String productionDate,
    @QtyConverter() required double qty,
    @Default(<String>[]) List<String> marks,
  }) = _PickingPick;

  factory PickingPick.fromJson(Map<String, dynamic> json) =>
      _$PickingPickFromJson(json);
}

/// Заказ сборки с подбором по строкам, коробами и открытыми пиками.
@freezed
abstract class PickingOrder with _$PickingOrder {
  const factory PickingOrder({
    required String id,
    required int number,
    @JsonKey(name: 'registry_date') required String registryDate,
    @JsonKey(name: 'invoice_number') @Default('') String invoiceNumber,
    @JsonKey(name: 'order_number') @Default('') String orderNumber,
    @Default('') String direction,
    @Default('') String client,
    @Default('') String address,
    required String status,
    @Default(false) bool mine,
    @Default(<PickingLine>[]) List<PickingLine> lines,
    @Default(<PickingBox>[]) List<PickingBox> boxes,
    @Default(<PickingPick>[]) List<PickingPick> picks,
  }) = _PickingOrder;

  factory PickingOrder.fromJson(Map<String, dynamic> json) =>
      _$PickingOrderFromJson(json);
}

/// Пик, сделанный на этом терминале: пик и, если его вернули, возврат - операциями очереди.
///
/// Источник пика нужен только телу операции: [sourceCellId] у россыпи, у короба - его id в
/// [PickingPick.loadUnitId]. [internalWarehouseId] - как ждёт сервер, пусто - «Основной».
@freezed
abstract class LocalPick with _$LocalPick {
  const factory LocalPick({
    required PickingPick pick,
    @JsonKey(name: 'pick_operation_id') required String pickOperationId,
    @JsonKey(name: 'unpick_operation_id') String? unpickOperationId,
    @JsonKey(name: 'source_cell_id') String? sourceCellId,
    @JsonKey(name: 'internal_warehouse_id')
    @Default('')
    String internalWarehouseId,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'unpicked_at') DateTime? unpickedAt,
  }) = _LocalPick;

  factory LocalPick.fromJson(Map<String, dynamic> json) =>
      _$LocalPickFromJson(json);
}

/// Слепок заказа на терминале: последний ответ сервера, когда он запрошен, свои пики и
/// выбранный короб отгрузки.
@freezed
abstract class PickingOrderDraft with _$PickingOrderDraft {
  const factory PickingOrderDraft({
    required PickingOrder order,

    /// Когда ушёл запрос, ответ на который лежит в [order]. Операции, подтверждённые позже,
    /// в нём могут не учитываться.
    @JsonKey(name: 'fetched_at') required DateTime fetchedAt,
    @Default(<LocalPick>[]) List<LocalPick> local,
    @JsonKey(name: 'current_box_id') String? currentBoxId,
  }) = _PickingOrderDraft;

  factory PickingOrderDraft.fromJson(Map<String, dynamic> json) =>
      _$PickingOrderDraftFromJson(json);
}

/// Итог отметки «не хватает»: номер пересчёта позиции и заведён ли он сейчас.
typedef ShortageResult = ({int? stocktakeNumber, bool created});
