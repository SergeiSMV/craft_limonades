import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/error/failure.dart';
import '../../features/contents/data/contents_api.dart';
import '../../features/contents/data/contents_dto.dart';
import '../../features/stock/data/catalog_api.dart';
import '../../features/stock/data/catalog_models.dart';
import 'internal_warehouses_repository.dart';

/// Место товара одной партии на складе: россыпью в ячейке или в коробе.
class PortalStockPlace {
  const PortalStockPlace({
    required this.cellAddress,
    required this.productionDate,
    required this.qty,
    required this.warehouseId,
    required this.warehouseName,
    this.loadUnitId,
    this.onDefaultWarehouse = true,
  });

  /// Адрес ячейки; ячейки нет в справочнике — пусто.
  final String cellAddress;

  /// Короб; `null` — россыпью.
  final String? loadUnitId;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;
  final double qty;
  final String warehouseId;
  final String warehouseName;

  /// На складе по умолчанию: в карточке такое место склад не подписывает — как на ТСД,
  /// пометка нужна только у брака и других особых складов.
  final bool onDefaultWarehouse;
}

/// Товар с остатком: сколько его на каждом внутреннем складе.
class PortalStockGood {
  const PortalStockGood({required this.good, required this.byWarehouse});

  final Good good;

  /// Количество по внутренним складам — по id склада.
  final Map<String, double> byWarehouse;

  /// Сколько товара на складе [warehouseId]; `null` — на всех.
  double qtyOn(String? warehouseId) {
    var total = 0.0;
    for (final e in byWarehouse.entries) {
      if (warehouseId == null || e.key == warehouseId) total += e.value;
    }
    return (total * 1000).roundToDouble() / 1000;
  }
}

/// Остатки склада для портала: товары с остатком, их места и внутренние склады.
class PortalStock {
  const PortalStock({
    required this.asOf,
    required this.goods,
    required this.places,
    required this.warehouses,
  });

  /// Момент, на который согласован снимок.
  final DateTime asOf;

  /// Товары с остатком больше нуля — по наименованию.
  final List<PortalStockGood> goods;

  /// Места товара — по id товара, вдоль стеллажа: по адресу, россыпь раньше коробов, по партии.
  final Map<String, List<PortalStockPlace>> places;
  final List<PortalWarehouse> warehouses;
}

/// Источник «Остатков склада» портала (ADHOC-56): тот же снимок склада, что кормит ТСД
/// (`GET /contents/snapshot`), со справочниками товаров, ячеек и внутренних складов.
///
/// Зачем снимок, а не отдельный отчёт: в нём и россыпь, и содержимое коробов, согласованные на
/// один момент, — те же цифры, что видит кладовщик. Снимок несёт только идентификаторы, поэтому
/// имена подставляются здесь, в памяти; на масштабе пилота это сотни строк.
/// Последний собранный результат держится в памяти: карточка товара в «Номенклатуре» берёт места
/// из него, не скачивая склад заново на каждое открытие. [load] с `refresh` — свежий снимок.
@lazySingleton
class WarehouseStockRepository {
  WarehouseStockRepository(this._contents, this._catalog, this._warehouses);

  final ContentsApi _contents;
  final CatalogApi _catalog;
  final InternalWarehousesRepository _warehouses;

  PortalStock? _last;

  /// Остатки склада; без [refresh] — последний собранный результат, если он есть.
  Future<Either<Failure, PortalStock>> load({bool refresh = true}) async {
    final cached = _last;
    if (!refresh && cached != null) return Right(cached);
    final results = await Future.wait([
      _contents.snapshot(),
      _catalog.listAllGoods(),
      _catalog.listAllCells(),
      _warehouses.list(),
    ]);
    for (final r in results) {
      if (r.isLeft) return Left(r.left);
    }
    final stock = build(
      snapshot: results[0].right as ContentsSnapshot,
      goods: results[1].right as List<Good>,
      cells: results[2].right as List<Cell>,
      warehouses: results[3].right as List<PortalWarehouse>,
    );
    _last = stock;
    return Right(stock);
  }

  /// Сборка остатков из снимка и справочников — отдельно от сети, чтобы проверять тестом.
  ///
  /// Склад строки без склада (сервер до P6-07) — склад по умолчанию. Товара нет в справочнике
  /// (заведён после его загрузки) — строка всё равно попадает в список, с пустым наименованием:
  /// остаток важнее подписи.
  static PortalStock build({
    required ContentsSnapshot snapshot,
    required List<Good> goods,
    required List<Cell> cells,
    required List<PortalWarehouse> warehouses,
  }) {
    final goodById = {for (final g in goods) g.id: g};
    final address = {for (final c in cells) c.id: c.address};
    final names = {for (final w in warehouses) w.id: w.name};
    final defaultId = warehouses
        .where((w) => w.isDefault)
        .map((w) => w.id)
        .firstOrNull;
    String warehouse(String id) => id.isEmpty ? (defaultId ?? '') : id;

    final places = <String, List<PortalStockPlace>>{};
    void add(String cellId, SnapshotLine l, String warehouseId, {String? box}) {
      if (l.qty <= 0) return;
      final w = warehouse(warehouseId);
      places
          .putIfAbsent(l.goodId, () => [])
          .add(
            PortalStockPlace(
              cellAddress: address[cellId] ?? '',
              loadUnitId: box,
              productionDate: l.productionDate,
              qty: l.qty,
              warehouseId: w,
              warehouseName: names[w] ?? '',
              onDefaultWarehouse: w == defaultId,
            ),
          );
    }

    for (final lu in snapshot.loadUnits) {
      for (final l in lu.lines) {
        add(lu.cellId, l, lu.internalWarehouseId, box: lu.id);
      }
    }
    for (final l in snapshot.loose) {
      add(l.cellId, l.line, l.internalWarehouseId);
    }

    final out = <PortalStockGood>[];
    for (final e in places.entries) {
      e.value.sort(_alongRack);
      final byWarehouse = <String, double>{};
      for (final p in e.value) {
        byWarehouse[p.warehouseId] = (byWarehouse[p.warehouseId] ?? 0) + p.qty;
      }
      out.add(
        PortalStockGood(
          good: goodById[e.key] ?? Good(id: e.key, name: '', uom: ''),
          byWarehouse: byWarehouse,
        ),
      );
    }
    out.sort((a, b) => a.good.name.compareTo(b.good.name));
    return PortalStock(
      asOf: snapshot.asOf,
      goods: out,
      places: places,
      warehouses: warehouses,
    );
  }

  /// Вдоль стеллажа: по адресу ячейки, в ячейке — россыпь, затем короба; внутри — по партии.
  static int _alongRack(PortalStockPlace a, PortalStockPlace b) {
    final byCell = a.cellAddress.compareTo(b.cellAddress);
    if (byCell != 0) return byCell;
    final byBox = (a.loadUnitId ?? '').compareTo(b.loadUnitId ?? '');
    if (byBox != 0) return byBox;
    return _batchKey(a.productionDate).compareTo(_batchKey(b.productionDate));
  }

  /// Дата партии DD-MM-YYYY как ключ сортировки YYYYMMDD.
  static String _batchKey(String date) {
    final p = date.split('-');
    return p.length == 3 ? '${p[2]}${p[1]}${p[0]}' : date;
  }
}
