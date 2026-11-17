import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../features/stock/domain/catalog_models.dart';
import '../internal_warehouses/internal_warehouses_repository.dart';

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

  /// Адрес ячейки; ячейки нет в справочнике - пусто.
  final String cellAddress;

  /// Короб; `null` - россыпью.
  final String? loadUnitId;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;
  final double qty;
  final String warehouseId;
  final String warehouseName;

  /// На складе по умолчанию: в карточке такое место склад не подписывает - как на ТСД,
  /// пометка нужна только у брака и других особых складов.
  final bool onDefaultWarehouse;
}

/// Товар с остатком: сколько его на каждом внутреннем складе.
class PortalStockGood {
  const PortalStockGood({required this.good, required this.byWarehouse});

  final Good good;

  /// Количество по внутренним складам - по id склада.
  final Map<String, double> byWarehouse;

  /// Сколько товара на складе [warehouseId]; `null` - на всех.
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

  /// Товары с остатком больше нуля - по наименованию.
  final List<PortalStockGood> goods;

  /// Места товара - по id товара, вдоль стеллажа: по адресу, россыпь раньше коробов, по партии.
  final Map<String, List<PortalStockPlace>> places;
  final List<PortalWarehouse> warehouses;
}

/// Источник «Остатков склада» портала (ADHOC-56): тот же снимок склада, что кормит ТСД
/// (`GET /contents/snapshot`), со справочниками товаров, ячеек и внутренних складов.
///
/// Зачем снимок, а не отдельный отчёт: в нём и россыпь, и содержимое коробов, согласованные на
/// один момент, - те же цифры, что видит кладовщик. Снимок несёт только идентификаторы, поэтому
/// имена подставляются здесь, в памяти; на масштабе пилота это сотни строк.
/// Последний собранный результат держится в памяти: карточка товара в «Номенклатуре» берёт места
/// из него, не скачивая склад заново на каждое открытие. [load] с `refresh` - свежий снимок.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `WarehouseStockRepositoryImpl` в `data`.
abstract interface class WarehouseStockRepository {
  /// Остатки склада; без [refresh] - последний собранный результат, если он есть.
  Future<Either<Failure, PortalStock>> load({bool refresh = true});
}
