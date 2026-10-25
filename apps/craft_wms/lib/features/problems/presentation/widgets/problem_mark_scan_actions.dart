import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/problem_cubit.dart';

/// Скан марки или групповой упаковки «Честного знака» в «Проблемах склада» (CZ-06).
///
/// Что: маркируемый товар помечают марками — какие именно единицы ушли в брак, офис и отгрузка
/// возврата потом берут ровно их. Где марка лежит, терминал знает из снимка со своей очередью
/// поверх.
/// Зачем отдельно от экрана: экран и так за порогом размера.
/// Как: групповая упаковка — её марки, лежащие там же, где первая, того же товара и партии.
/// Решение «отметить, добавить или отказать» — за кубитом.
mixin ProblemMarkScanActions<T extends StatefulWidget> on State<T> {
  void snack(String text);

  /// Ячейка справочника терминала по условию; `null` — такой нет.
  Future<Cell?> cellWhere(bool Function(Cell) test);

  ProblemCubit get _problem => context.read<ProblemCubit>();
  ContentsRepository get _contents => getIt<ContentsRepository>();

  /// Отсканирован КИ марки или групповой упаковки.
  Future<void> onMarkScan(String code) async {
    final found = await _contents.marksByCode(code);
    if (found.isEmpty) {
      if (mounted) snack(t.movement.markUnknown);
      return;
    }
    final first = found.first;
    final box = first.inBox ? await _box(first.loadUnitId!) : null;
    final cellId = box?.cellId ?? first.cellId;
    final cell = cellId == null ? null : await cellWhere((c) => c.id == cellId);
    final good = await getIt<CatalogRepository>().goodById(first.goodId);
    final warehouse = first.inBox
        ? box?.internalWarehouseId
        : first.internalWarehouseId;
    final name = await _warehouseName(warehouse);
    if (!mounted) return;
    if (cell == null || (first.inBox && box == null)) {
      snack(t.movement.markUnknown);
      return;
    }
    if (good == null) {
      snack(t.czScan.goodNotLoaded);
      return;
    }
    final marks = [
      for (final m in found)
        if (m.goodId == first.goodId &&
            m.productionDate == first.productionDate &&
            m.samePlace(first))
          m.cis,
    ];
    _problem.chooseMarks(
      marks: marks,
      line: ContentLine(
        goodId: good.id,
        goodName: good.name,
        goodCode: good.code,
        uom: good.uom,
        productionDate: first.productionDate,
        qty: marks.length.toDouble(),
        internalWarehouseId: warehouse,
        internalWarehouseName: name,
      ),
      cell: cell,
      box: box,
    );
  }

  /// Короб марки с наложенной очередью; `null` — его нет ни на сервере, ни в снимке.
  Future<LoadUnitView?> _box(String id) async {
    final res = await _contents.loadUnit(id);
    return res.isRight ? res.right.value : null;
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
