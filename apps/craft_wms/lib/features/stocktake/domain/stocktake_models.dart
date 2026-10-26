import 'package:freezed_annotation/freezed_annotation.dart';

part 'stocktake_models.freezed.dart';
part 'stocktake_models.g.dart';

/// Сущности пересчёта на ТСД (P10-04). Слой `domain` фичи: ни Flutter, ни сети, ни базы.
/// JSON нужен черновику подсчёта: ячейка переживает выход с экрана и перезапуск.

/// Вид области пересчёта — как на сервере.
abstract final class StocktakeScope {
  static const cells = 'cells';
  static const group = 'group';
  static const supplier = 'supplier';
  static const good = 'good';
  static const internalWarehouse = 'internal_warehouse';
  static const all = 'all';
}

/// Статус ячейки пересчёта так, как его видит этот работник: чужая зависшая — свободная.
abstract final class StocktakeCellStatus {
  static const pending = 'pending';
  static const taken = 'taken';
  static const counting = 'counting';
  static const counted = 'counted';
  static const disrupted = 'disrupted';
}

/// Вид позиции снимка: россыпь или короб целиком.
abstract final class StocktakePositionKind {
  static const loose = 'loose';
  static const box = 'box';
}

/// Товар позиции — то, что нужно показать человеку.
@freezed
abstract class StocktakeGood with _$StocktakeGood {
  const factory StocktakeGood({
    required String id,
    @Default('') String code,
    required String name,
    required String uom,
  }) = _StocktakeGood;

  factory StocktakeGood.fromJson(Map<String, dynamic> json) =>
      _$StocktakeGoodFromJson(json);
}

/// Ячейка пересчёта.
@freezed
abstract class StocktakeCell with _$StocktakeCell {
  const factory StocktakeCell({
    required String id,
    @JsonKey(name: 'stocktake_id') required String stocktakeId,
    @JsonKey(name: 'cell_id') required String cellId,
    required String address,
    required String status,
    @JsonKey(name: 'taken_by') @Default('') String takenBy,
    @JsonKey(name: 'started_at') DateTime? startedAt,
    @Default(false) bool mine,
  }) = _StocktakeCell;

  const StocktakeCell._();

  /// Свободна — взять может любой.
  bool get isFree => status == StocktakeCellStatus.pending;

  /// Своя, ещё не подсчитанная: взята, на подсчёте или сбита.
  bool get isMineOpen => mine && status != StocktakeCellStatus.counted;

  factory StocktakeCell.fromJson(Map<String, dynamic> json) =>
      _$StocktakeCellFromJson(json);
}

/// Позиция снимка ячейки — что искать, без количеств (слепой счёт, решение 2026-10-26).
///
/// Короб ([loadUnitId]) ЛИБО россыпь ([good] · [productionDate] · склад). [internalWarehouseId]
/// приведён к соглашению терминала: `null` — «Основной».
@freezed
abstract class StocktakePosition with _$StocktakePosition {
  const factory StocktakePosition({
    required String kind,
    @JsonKey(name: 'internal_warehouse_id') String? internalWarehouseId,
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    @JsonKey(name: 'cz_code') String? czCode,
    StocktakeGood? good,

    /// Дата партии, DD-MM-YYYY — в транспортном виде.
    @JsonKey(name: 'production_date') String? productionDate,
    @Default(false) bool marked,
  }) = _StocktakePosition;

  const StocktakePosition._();

  bool get isBox => kind == StocktakePositionKind.box;

  factory StocktakePosition.fromJson(Map<String, dynamic> json) =>
      _$StocktakePositionFromJson(json);
}

/// Ячейка на подсчёте с позициями снимка.
@freezed
abstract class StocktakeCellView with _$StocktakeCellView {
  const factory StocktakeCellView({
    required StocktakeCell cell,
    @Default(<StocktakePosition>[]) List<StocktakePosition> positions,
  }) = _StocktakeCellView;

  factory StocktakeCellView.fromJson(Map<String, dynamic> json) =>
      _$StocktakeCellViewFromJson(json);
}

/// Пересчёт с ходом выполнения — шапка и все ячейки.
@freezed
abstract class StocktakeInfo with _$StocktakeInfo {
  const factory StocktakeInfo({
    required String id,
    required int number,
    @JsonKey(name: 'scope_kind') required String scopeKind,
    required String status,
    @Default(<StocktakeCell>[]) List<StocktakeCell> cells,
  }) = _StocktakeInfo;

  const StocktakeInfo._();

  /// Сколько ячеек подсчитано.
  int get counted =>
      cells.where((c) => c.status == StocktakeCellStatus.counted).length;

  /// Пересчёт закрыт.
  bool get closed => status == 'closed';

  factory StocktakeInfo.fromJson(Map<String, dynamic> json) =>
      _$StocktakeInfoFromJson(json);
}

/// Заведённый пересчёт: номер и сколько ячеек дала область.
typedef StocktakeCreated = ({String id, int number, int cells});
