import 'package:freezed_annotation/freezed_annotation.dart';

import 'stocktake_models.dart';

part 'stocktake_count.freezed.dart';
part 'stocktake_count.g.dart';

/// Подсчёт ячейки пересчёта на ТСД (P10-04): что насчитано, и правила, общие для экрана,
/// черновика и тела операции `stocktake_cell_submit`. Слой `domain`: без Flutter и сети.

/// Насчитанная россыпь позиции: товар · партия · склад, количество; у маркируемого - марки,
/// количество - их число.
@freezed
abstract class CountLine with _$CountLine {
  const factory CountLine({
    required StocktakeGood good,

    /// Дата партии, DD-MM-YYYY - в транспортном виде.
    @JsonKey(name: 'production_date') required String productionDate,

    /// Склад товара; `null` - «Основной».
    @JsonKey(name: 'internal_warehouse_id') String? internalWarehouseId,
    required double qty,
    @Default(<String>[]) List<String> marks,
  }) = _CountLine;

  const CountLine._();

  /// Та же ли позиция: товар, партия, склад.
  bool samePosition(String goodId, String date, String? warehouseId) =>
      good.id == goodId &&
      productionDate == date &&
      internalWarehouseId == warehouseId;

  factory CountLine.fromJson(Map<String, dynamic> json) =>
      _$CountLineFromJson(json);
}

/// Найденный короб. [foreign] - его нет в снимке ячейки: учётный короб из другого места,
/// сервер перенесёт его сюда.
@freezed
abstract class CountBox with _$CountBox {
  const factory CountBox({
    @JsonKey(name: 'load_unit_id') required String loadUnitId,
    @JsonKey(name: 'cz_code') String? czCode,
    @Default(false) bool foreign,
  }) = _CountBox;

  factory CountBox.fromJson(Map<String, dynamic> json) =>
      _$CountBoxFromJson(json);
}

/// Подсчёт ячейки: снимок, насчитанная россыпь и найденные короба.
@freezed
abstract class StocktakeCount with _$StocktakeCount {
  const factory StocktakeCount({
    required StocktakeCellView view,
    @Default(<CountLine>[]) List<CountLine> lines,
    @Default(<CountBox>[]) List<CountBox> boxes,
  }) = _StocktakeCount;

  const StocktakeCount._();

  StocktakeCell get cell => view.cell;

  /// Короба снимка.
  List<StocktakePosition> get boxPositions => [
    for (final p in view.positions)
      if (p.isBox) p,
  ];

  /// Россыпь снимка.
  List<StocktakePosition> get loosePositions => [
    for (final p in view.positions)
      if (!p.isBox) p,
  ];

  /// Короб найден.
  bool boxFound(String loadUnitId) =>
      boxes.any((b) => b.loadUnitId.toLowerCase() == loadUnitId.toLowerCase());

  /// Насчитанное по позиции россыпи снимка; `null` - ещё ничего.
  CountLine? lineOf(StocktakePosition p) => lines
      .where(
        (l) => l.samePosition(
          p.good!.id,
          p.productionDate ?? '',
          p.internalWarehouseId,
        ),
      )
      .firstOrNull;

  /// Позиции россыпи снимка с товаром [goodId].
  List<StocktakePosition> positionsOf(String goodId) => [
    for (final p in loosePositions)
      if (p.good?.id == goodId) p,
  ];

  /// Насчитанное сверх снимка - излишек: позиции, которой в снимке нет.
  List<CountLine> get extraLines => [
    for (final l in lines)
      if (!loosePositions.any(
        (p) =>
            p.good?.id == l.good.id &&
            p.productionDate == l.productionDate &&
            p.internalWarehouseId == l.internalWarehouseId,
      ))
        l,
  ];

  /// Короба, найденные не по снимку.
  List<CountBox> get foreignBoxes => [
    for (final b in boxes)
      if (b.foreign) b,
  ];

  /// Чего не нашли: короба снимка без скана и россыпь снимка без насчитанного (или с нулём).
  /// Короба уйдут в «Не найдено», россыпь - недостачей.
  List<StocktakePosition> get missing => [
    for (final p in boxPositions)
      if (!boxFound(p.loadUnitId!)) p,
    for (final p in loosePositions)
      if ((lineOf(p)?.qty ?? 0) <= 0) p,
  ];

  /// Марка уже отсканирована в этом подсчёте.
  bool hasMark(String cis) => lines.any((l) => l.marks.contains(cis));

  /// Тело операции `stocktake_cell_submit` - формат эталона
  /// `testdata/stocktake_cell_submit.json`. Нулевые строки не шлются: не названная позиция
  /// и так - недостача.
  Map<String, dynamic> payload() => {
    'stocktake_cell_id': cell.id,
    'loose': [
      for (final l in lines)
        if (l.qty > 0)
          {
            'good_id': l.good.id,
            'production_date': l.productionDate,
            'internal_warehouse_id': l.internalWarehouseId,
            'qty': l.qty,
            if (l.marks.isNotEmpty) 'marks': l.marks,
          },
    ],
    'boxes': [for (final b in boxes) b.loadUnitId],
  };

  factory StocktakeCount.fromJson(Map<String, dynamic> json) =>
      _$StocktakeCountFromJson(json);
}
