import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../cz/domain/cz_stock_marks.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/movement_models.dart';
import '../bloc/movement_cubit.dart';

/// Где лежит марка для перемещения: место, его ячейка и склад товара (`null` — «Основной»).
typedef MarkSpot = ({MovePlace place, Cell cell, String? warehouseId});

/// Скан марки или групповой упаковки «Честного знака» в перемещении (CZ-06).
///
/// Что: маркируемый товар берётся в руки марками — без диалога количества; где марка лежит,
/// терминал знает из снимка со своей очередью поверх и из строк этого сеанса.
/// Зачем отдельно от экрана: экран и так за порогом размера, а у ветки марок своё правило места.
/// Как: групповая упаковка — набор своих марок; берутся те, что лежат там же, где первая, того
/// же товара, партии и склада. Решение «взять, добавить или отказать» — за кубитом.
mixin MoveMarkScanActions<T extends StatefulWidget> on State<T> {
  void snack(String text);

  /// Ячейка справочника терминала по условию; `null` — такой нет.
  Future<Cell?> cellWhere(bool Function(Cell) test);

  MovementCubit get _move => context.read<MovementCubit>();
  ContentsRepository get _contents => getIt<ContentsRepository>();

  /// Отсканирован КИ марки или групповой упаковки.
  Future<void> onMarkScan(String code) async {
    final found = await stockMarksByCode(
      code,
      contents: _contents,
      cz: getIt<CzScanRepository>(),
      defaultWarehouseId: getIt<InternalWarehouses>().defaultId,
    );
    final spots = <(StockMark, MarkSpot)>[];
    for (final m in found) {
      if (await _spotOf(m) case final spot?) spots.add((m, spot));
    }
    if (!mounted) return;
    if (spots.isEmpty) {
      snack(t.movement.markUnknown);
      return;
    }
    final (first, spot) = spots.first;
    final good = await getIt<CatalogRepository>().goodById(first.goodId);
    final name = await _warehouseName(spot.warehouseId);
    if (!mounted) return;
    if (good == null) {
      snack(t.czScan.goodNotLoaded);
      return;
    }
    _move.takeMarks(
      marks: [
        for (final (m, s) in spots)
          if (m.goodId == first.goodId &&
              m.productionDate == first.productionDate &&
              s.warehouseId == spot.warehouseId &&
              s.place.samePlace(spot.place))
            m.cis,
      ],
      good: MoveGood(
        id: good.id,
        name: good.name,
        code: good.code,
        uom: good.uom,
      ),
      productionDate: first.productionDate,
      from: spot.place,
      cell: spot.cell,
      internalWarehouseId: spot.warehouseId,
      internalWarehouseName: name,
    );
  }

  /// Где марка сейчас: строка сеанса, которая её положила; иначе её короб там, где он лежит
  /// с учётом сеанса; иначе её ячейка. `null` — место не найти (короба или ячейки нет).
  Future<MarkSpot?> _spotOf(StockMark m) async {
    final s = _move.state;
    final moved = s.markPlaceInSession(m.cis);
    if (moved != null) {
      final line = s.lines.lastWhere((l) => l.marks.contains(m.cis));
      final cellId = moved.isBox
          ? s.boxCellInSession(moved.loadUnitId!) ?? moved.cellId
          : moved.cellId;
      final cell = await cellWhere((c) => c.id == cellId);
      if (cell == null) return null;
      return (
        place: moved.copyWith(cellId: cell.id, cellAddress: cell.address),
        cell: cell,
        warehouseId: line.internalWarehouseId,
      );
    }
    if (m.inBox) {
      // Короб марки — из снимка терминала; сервер — только если его там нет (ADHOC-70).
      var box = await _contents.cachedLoadUnit(m.loadUnitId!);
      if (box == null) {
        final res = await _contents.loadUnit(m.loadUnitId!);
        box = res.isRight ? res.right.value : null;
      }
      if (box == null) return null;
      final cellId = s.boxCellInSession(box.id) ?? box.cellId;
      final cell = cellId == null
          ? null
          : await cellWhere((c) => c.id == cellId);
      if (cell == null) return null;
      return (
        place: MovePlace(
          cellId: cell.id,
          cellAddress: cell.address,
          loadUnitId: box.id,
          internalWarehouseId: box.internalWarehouseId,
        ),
        cell: cell,
        warehouseId: box.internalWarehouseId,
      );
    }
    final cell = await cellWhere((c) => c.id == m.cellId);
    if (cell == null) return null;
    return (
      place: MovePlace(cellId: cell.id, cellAddress: cell.address),
      cell: cell,
      warehouseId: m.internalWarehouseId,
    );
  }

  /// Как склад товара показывается человеку; «Основной» (`null`) не подписывается.
  Future<String?> _warehouseName(String? id) async {
    if (id == null) return null;
    for (final w in await getIt<InternalWarehouses>().all()) {
      if (w.id == id) return w.name;
    }
    return null;
  }
}
