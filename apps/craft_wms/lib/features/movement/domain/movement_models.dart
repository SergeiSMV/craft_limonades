import 'package:freezed_annotation/freezed_annotation.dart';

part 'movement_models.freezed.dart';
part 'movement_models.g.dart';

/// Сущности перемещения на ТСД (P6-04). Слой `domain` фичи: ни Flutter, ни сети, ни базы —
/// только данные сеанса. JSON нужен черновику: сеанс переживает выход с экрана и перезапуск.

/// Место на складе: россыпь ячейки ИЛИ короб в ячейке.
///
/// Короб на сервер уходит своим идентификатором — ячейку сервер знает сам; здесь она нужна
/// человеку (адрес в строке сеанса) и проверкам на терминале (ячейка приёмки, другой склад).
@freezed
abstract class MovePlace with _$MovePlace {
  const factory MovePlace({
    @JsonKey(name: 'cell_id') required String cellId,
    @JsonKey(name: 'cell_address') required String cellAddress,
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
  }) = _MovePlace;

  const MovePlace._();

  bool get isBox => loadUnitId != null;

  /// То же ли это место. Короб — по себе самому, где бы он ни лежал: переехав в сеансе, он
  /// остаётся тем же коробом со своим составом. Россыпь — по ячейке.
  bool samePlace(MovePlace other) => isBox || other.isBox
      ? loadUnitId == other.loadUnitId
      : cellId == other.cellId;

  factory MovePlace.fromJson(Map<String, dynamic> json) =>
      _$MovePlaceFromJson(json);
}

/// Товар строки — то, что нужно показать человеку.
@freezed
abstract class MoveGood with _$MoveGood {
  const factory MoveGood({
    required String id,
    required String name,
    String? code,
    required String uom,
  }) = _MoveGood;

  factory MoveGood.fromJson(Map<String, dynamic> json) =>
      _$MoveGoodFromJson(json);
}

/// Строка сеанса: ГЕ целиком ЛИБО товар (партия, количество) — откуда и куда.
@freezed
abstract class MoveLine with _$MoveLine {
  const factory MoveLine({
    /// ГЕ целиком. Товарных полей у такой строки нет.
    @JsonKey(name: 'load_unit_id') String? loadUnitId,
    MoveGood? good,

    /// Дата партии, DD-MM-YYYY — в транспортном виде, как её несут сервер и снимок.
    @JsonKey(name: 'production_date') String? productionDate,
    double? qty,
    required MovePlace from,
    required MovePlace to,
  }) = _MoveLine;

  const MoveLine._();

  bool get isWholeBox => loadUnitId != null;

  factory MoveLine.fromJson(Map<String, dynamic> json) =>
      _$MoveLineFromJson(json);
}
