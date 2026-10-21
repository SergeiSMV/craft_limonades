import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../domain/movement_models.dart';

/// Подписи перемещения для человека: коробы — коротким кодом с ярлыка, партии — датой.

/// Короткий код короба, как на ярлыке.
String boxCode(String loadUnitId) =>
    LoadUnitLabel(loadUnitId).shortCodeFormatted;

/// Место: короб — «короб 1A2B 3C4D в A-1-1», россыпь — адрес ячейки.
String placeLabel(MovePlace p) => p.isBox
    ? t.movement.placeBox(code: boxCode(p.loadUnitId!), cell: p.cellAddress)
    : p.cellAddress;

/// Товар с партией и количеством; [warehouse] — склад не «Основной» («Брак» …) — дописывается.
String goodsLabel(
  MoveGood good,
  String productionDate,
  double qty, {
  String? warehouse,
}) => withWarehouse(
  t.movement.goods(
    name: good.name,
    date: batchDate(productionDate),
    qty: fmtQty(qty),
    uom: good.uom,
  ),
  warehouse,
);

/// Подпись с меткой склада (P6-07-2): «… · Брак». «Основной» не подписывается.
String withWarehouse(String text, String? warehouse) => warehouse == null
    ? text
    : t.movement.withWarehouse(text: text, warehouse: warehouse);
