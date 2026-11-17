import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/error/failure.dart';
import '../../features/contents/data/contents_api.dart';
import '../../features/contents/data/contents_dto.dart';
import '../../features/stock/data/catalog_api.dart';
import '../../features/stock/domain/catalog_models.dart';
import '../domain/stock/warehouse_stock_repository.dart';
import '../domain/internal_warehouses/internal_warehouses_repository.dart';

/// Источник «Остатков склада» портала (ADHOC-56): тот же снимок склада, что кормит ТСД
/// (`GET /contents/snapshot`), со справочниками товаров, ячеек и внутренних складов.
///
/// Зачем снимок, а не отдельный отчёт: в нём и россыпь, и содержимое коробов, согласованные на
/// один момент, - те же цифры, что видит кладовщик. Снимок несёт только идентификаторы, поэтому
/// имена подставляются здесь, в памяти; на масштабе пилота это сотни строк.
/// Последний собранный результат держится в памяти: карточка товара в «Номенклатуре» берёт места
/// из него, не скачивая склад заново на каждое открытие. [load] с `refresh` - свежий снимок.
@LazySingleton(as: WarehouseStockRepository)
class WarehouseStockRepositoryImpl implements WarehouseStockRepository {
  WarehouseStockRepositoryImpl(this._contents, this._catalog, this._warehouses);

  final ContentsApi _contents;
  final CatalogApi _catalog;
  final InternalWarehousesRepository _warehouses;

  PortalStock? _last;

  /// Остатки склада; без [refresh] - последний собранный результат, если он есть.
  @override
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

  /// Сборка остатков из снимка и справочников - отдельно от сети, чтобы проверять тестом.
  ///
  /// Склад строки без склада (сервер до P6-07) - склад по умолчанию. Товара нет в справочнике
  /// (заведён после его загрузки) - строка всё равно попадает в список, с пустым наименованием:
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

  /// Вдоль стеллажа: по адресу ячейки, в ячейке - россыпь, затем короба; внутри - по партии.
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
