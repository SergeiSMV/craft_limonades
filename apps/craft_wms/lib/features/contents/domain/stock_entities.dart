/// Остатки по товарам из снимка склада (ADHOC-33).
///
/// Слой `domain` фичи `contents`: раздел «Остатки» и карточка товара читают остаток не с сервера
/// (`GET /stock`), а из того же снимка, что ячейки и короба, - со своей очередью поверх.
library;

/// Место, где лежит товар одной партии: россыпью в ячейке или в коробе.
class StockPlace {
  const StockPlace({
    required this.goodId,
    required this.cellId,
    this.cellAddress,
    this.loadUnitId,
    required this.productionDate,
    required this.qty,
    this.internalWarehouseId,
    this.internalWarehouseName,
    this.pending = false,
  });

  final String goodId;
  final String cellId;

  /// `null` - ячейки нет в справочнике терминала.
  final String? cellAddress;

  /// Короб, в котором лежит товар; `null` - россыпью.
  final String? loadUnitId;

  /// Дата партии, DD-MM-YYYY.
  final String productionDate;
  final double qty;

  /// Внутренний склад (P6-07-2); `null` - «Основной».
  final String? internalWarehouseId;

  /// Как склад показывается человеку; `null` - «Основной».
  final String? internalWarehouseName;

  /// Место изменила своя неотправленная операция.
  final bool pending;
}

/// Остаток товара на складе по внутренним складам - строка вкладки «Товары».
class GoodStock {
  const GoodStock({
    required this.goodId,
    this.name,
    this.code,
    this.uom,
    this.groupId,
    this.groupName,
    this.supplierId,
    required this.byWarehouse,
    this.pending = false,
  });

  final String goodId;

  /// `null` - товара нет в справочнике терминала (заведён после загрузки).
  final String? name;
  final String? code;
  final String? uom;
  final String? groupId;
  final String? groupName;
  final String? supplierId;

  /// Количество по внутренним складам; ключ `null` - «Основной».
  final Map<String?, double> byWarehouse;

  /// Остаток изменила своя неотправленная операция.
  final bool pending;

  /// Сколько товара на складах [warehouses]; пустой набор - на всех.
  double qtyOn(Set<String?> warehouses) {
    var total = 0.0;
    for (final e in byWarehouse.entries) {
      if (warehouses.isEmpty || warehouses.contains(e.key)) total += e.value;
    }
    return (total * 1000).roundToDouble() / 1000;
  }
}
