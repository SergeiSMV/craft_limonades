import 'package:craft_wms/features/contents/data/contents_dto.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/portal/data/warehouse_stock_repository_impl.dart';
import 'package:craft_wms/portal/domain/internal_warehouses/internal_warehouses_repository.dart';
import 'package:flutter_test/flutter_test.dart';

SnapshotLine line(String good, String date, double qty) =>
    SnapshotLine(goodId: good, batchId: 'b', productionDate: date, qty: qty);

PortalWarehouse warehouse(String id, {bool isDefault = false}) =>
    PortalWarehouse(
      id: id,
      code: id,
      name: 'Склад $id',
      isDefault: isDefault,
      isActive: true,
      inUse: true,
    );

/// ADHOC-56: сборка «Остатков склада» из снимка - суммы по складам, места вдоль стеллажа.
void main() {
  final stock = WarehouseStockRepositoryImpl.build(
    snapshot: ContentsSnapshot(
      asOf: DateTime.utc(2026, 10, 30),
      loadUnits: [
        SnapshotLoadUnit(
          id: 'lu1',
          kind: 'box',
          cellId: 'c2',
          createdAt: DateTime.utc(2026),
          internalWarehouseId: 'w2',
          lines: [line('g1', '01-02-2026', 5), line('g2', '01-02-2026', 0)],
        ),
      ],
      loose: [
        SnapshotLoose(
          cellId: 'c1',
          internalWarehouseId: '',
          line: line('g1', '01-01-2026', 3),
        ),
        SnapshotLoose(
          cellId: 'c2',
          internalWarehouseId: 'w1',
          line: line('g3', '01-01-2026', 2),
        ),
      ],
    ),
    goods: const [
      Good(id: 'g1', name: 'Чипсы', uom: 'шт'),
      Good(id: 'g2', name: 'Пусто', uom: 'шт'),
    ],
    cells: const [
      Cell(id: 'c1', warehouseId: 'x', address: 'A-01'),
      Cell(id: 'c2', warehouseId: 'x', address: 'A-02'),
    ],
    warehouses: [warehouse('w1', isDefault: true), warehouse('w2')],
  );

  test(
    'нулевые строки отброшены, товар не из справочника - с пустым именем',
    () {
      expect(stock.goods.map((s) => s.good.id), ['g3', 'g1']);
      expect(stock.places.containsKey('g2'), isFalse);
    },
  );

  test('без склада - склад по умолчанию; остаток по складу и всего', () {
    final g1 = stock.goods.firstWhere((s) => s.good.id == 'g1');
    expect(g1.qtyOn(null), 8);
    expect(g1.qtyOn('w1'), 3);
    expect(g1.qtyOn('w2'), 5);
  });

  test('места вдоль стеллажа - с адресом, коробом и именем склада', () {
    final places = stock.places['g1']!;
    expect(places.map((p) => p.cellAddress), ['A-01', 'A-02']);
    expect(places.first.loadUnitId, isNull);
    expect(places.first.warehouseName, 'Склад w1');
    expect(places.last.loadUnitId, 'lu1');
    expect(places.first.onDefaultWarehouse, isTrue);
    expect(places.last.onDefaultWarehouse, isFalse);
  });
}
