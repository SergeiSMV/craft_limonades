import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../domain/stocktake_models.dart';

/// Подписи пересчёта для человека (P10-04).

/// Вид области: «весь склад», «ячейки» …
String scopeLabel(String kind) => switch (kind) {
  StocktakeScope.cells => t.stocktake.scopeCells,
  StocktakeScope.group => t.stocktake.scopeGroup,
  StocktakeScope.supplier => t.stocktake.scopeSupplier,
  StocktakeScope.good => t.stocktake.scopeGood,
  StocktakeScope.internalWarehouse => t.stocktake.scopeInternalWarehouse,
  StocktakeScope.all => t.stocktake.scopeAll,
  _ => kind,
};

/// Что с моей ячейкой: взята, на подсчёте, сбита.
String myCellStatus(StocktakeCell c) => switch (c.status) {
  StocktakeCellStatus.counting => t.stocktake.statusCounting,
  StocktakeCellStatus.disrupted => t.stocktake.statusDisrupted,
  _ => t.stocktake.statusTaken,
};

/// Строки позиции россыпи — каждый факт своей подписанной строкой: партия, склад (если не
/// «Основной»), что насчитано.
List<String> looseLines({
  required String productionDate,
  required String? warehouseName,
  required double? qty,
  required String uom,
  bool marked = false,
  int marks = 0,
}) => [
  t.stocktake.batch(date: batchDate(productionDate)),
  if (warehouseName != null) t.stocktake.warehouse(name: warehouseName),
  if (marked && marks > 0)
    t.stocktake.marksCount(count: marks)
  else if (qty != null && qty > 0)
    t.stocktake.countedQty(qty: fmtQty(qty), uom: uom)
  else
    t.stocktake.countedNone,
  if (marked) t.stocktake.marked,
];
