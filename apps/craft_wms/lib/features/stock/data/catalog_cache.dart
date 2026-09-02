import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/utils/search_text.dart';
import 'catalog_models.dart';

/// Имена справочников для отметок о синхронизации.
abstract final class CatalogName {
  static const goods = 'goods';
  static const groups = 'groups';
  static const suppliers = 'suppliers';
  static const cells = 'cells';
  static const barcodes = 'barcodes';

  /// Все справочники, которые тянет синхронизация.
  static const all = [goods, groups, suppliers, cells, barcodes];
}

/// Чтение и запись кэша справочников (P2-02).
///
/// Что: единственное место, где доменные модели превращаются в строки локальной базы и обратно.
/// Зачем: репозиторий не должен знать про drift, а база — про модели API; иначе замена одного
///        потянет за собой другое.
/// Как: запись справочника — всегда полная замена в транзакции (см. [_replace]); чтение
///      повторяет семантику серверного API, чтобы экраны не различали источник данных.
///
/// Лежит рядом с `CatalogRepository`, а не в `core`: обе стороны работают с доменными моделями
/// фичи `stock`, и `stock_entry` уже берёт репозиторий отсюда же.
@lazySingleton
class CatalogCache {
  CatalogCache(this._db);

  final AppDatabase _db;

  //* --- запись --- *//

  /// Полная замена содержимого справочника в одной транзакции.
  ///
  /// Именно замена, а не слияние: сервер отдаёт справочник целиком, и удалённые на сервере
  /// записи иначе остались бы в кэше навсегда. Транзакция нужна, чтобы падение посреди записи
  /// не оставило половину справочника — лучше прежний кэш целиком, чем новый наполовину.
  Future<void> _replace<T extends Table, D>(
    TableInfo<T, D> table,
    String catalog,
    List<Insertable<D>> rows,
  ) {
    return _db.transaction(() async {
      await _db.delete(table).go();
      await _db.batch((batch) => batch.insertAll(table, rows));
      await _db
          .into(_db.catalogSyncMarks)
          .insertOnConflictUpdate(
            CatalogSyncMarksCompanion.insert(
              catalog: catalog,
              syncedAt: DateTime.now(),
            ),
          );
    });
  }

  /// Уложить товары. `searchText` считается здесь, при записи: нормализация нужна один раз
  /// на товар, а не на каждый поисковый запрос.
  Future<void> putGoods(List<Good> goods) => _replace(
    _db.cachedGoods,
    CatalogName.goods,
    goods
        .map(
          (g) => CachedGoodsCompanion.insert(
            id: g.id,
            code: Value(g.code),
            name: g.name,
            fullName: Value(g.fullName),
            uom: g.uom,
            groupId: Value(g.groupId),
            groupName: Value(g.groupName),
            supplierId: Value(g.supplierId),
            supplierName: Value(g.supplierName),
            isActive: Value(g.isActive),
            searchText: normalizeSearchText(
              [g.name, g.code ?? '', g.fullName ?? ''].join(' '),
            ),
          ),
        )
        .toList(),
  );

  Future<void> putGroups(List<NomenclatureGroup> groups) => _replace(
    _db.cachedGroups,
    CatalogName.groups,
    groups
        .map(
          (g) => CachedGroupsCompanion.insert(
            id: g.id,
            code: g.code,
            name: g.name,
            parentId: Value(g.parentId),
          ),
        )
        .toList(),
  );

  Future<void> putSuppliers(List<Supplier> suppliers) => _replace(
    _db.cachedSuppliers,
    CatalogName.suppliers,
    suppliers
        .map((s) => CachedSuppliersCompanion.insert(id: s.id, name: s.name))
        .toList(),
  );

  Future<void> putCells(List<Cell> cells) => _replace(
    _db.cachedCells,
    CatalogName.cells,
    cells
        .map(
          (c) => CachedCellsCompanion.insert(
            id: c.id,
            warehouseId: c.warehouseId,
            address: c.address,
            type: Value(c.type),
            isFloor: Value(c.isFloor),
            isActive: Value(c.isActive),
            addressLower: c.address.toLowerCase(),
          ),
        )
        .toList(),
  );

  /// Уложить привязки ШК. [entries] — пары «штрихкод → товар».
  Future<void> putBarcodes(
    List<({String barcode, String goodId, String? symbology})> entries,
  ) => _replace(
    _db.cachedBarcodes,
    CatalogName.barcodes,
    entries
        .map(
          (e) => CachedBarcodesCompanion.insert(
            barcode: e.barcode,
            goodId: e.goodId,
            symbology: Value(e.symbology),
          ),
        )
        .toList(),
  );

  /// Точечно добавить привязку — после успешной привязки ШК на сервере, чтобы кэш не отстал
  /// до следующей синхронизации. Полной заменой тут пользоваться нельзя: остальные привязки
  /// никуда не делись.
  Future<void> addBarcode({
    required String barcode,
    required String goodId,
    String? symbology,
  }) => _db
      .into(_db.cachedBarcodes)
      .insertOnConflictUpdate(
        CachedBarcodesCompanion.insert(
          barcode: barcode,
          goodId: goodId,
          symbology: Value(symbology),
        ),
      );

  /// Точечно снять привязку — после успешной отвязки на сервере.
  Future<void> removeBarcode(String barcode) => (_db.delete(
    _db.cachedBarcodes,
  )..where((t) => t.barcode.equals(barcode))).go();

  //* --- чтение --- *//

  /// Время последней успешной загрузки справочника; `null` — не грузился ни разу.
  Future<DateTime?> syncedAt(String catalog) async {
    final row = await (_db.select(
      _db.catalogSyncMarks,
    )..where((t) => t.catalog.equals(catalog))).getSingleOrNull();
    return row?.syncedAt;
  }

  /// Какие справочники загружены хотя бы раз.
  ///
  /// Готовность считается по каждому отдельно, а не «все или ничего»: один недоступный
  /// справочник не должен отключать офлайн для остальных. Так, пока на сервере нет выгрузки
  /// привязок ШК, товары и ячейки всё равно читаются из кэша, а резолв по ШК идёт сетью.
  Future<Set<String>> loadedCatalogs() async {
    final marks = await _db.select(_db.catalogSyncMarks).get();
    return marks.map((m) => m.catalog).toSet();
  }

  /// Загружен ли конкретный справочник.
  Future<bool> has(String catalog) async =>
      (await loadedCatalogs()).contains(catalog);

  /// Поиск товаров: «все слова присутствуют, порядок не важен» — как на сервере (P-FS-17).
  ///
  /// [groupIds] — уже развёрнутое поддерево групп: разворачивать его здесь нельзя, потому что
  /// дерево нужно целиком, а это забота вызывающего ([descendantGroupIds]).
  Future<Paged<Good>> searchGoods({
    String? query,
    List<String>? groupIds,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) async {
    Expression<bool> predicate($CachedGoodsTable t) {
      var where = const Constant(true) as Expression<bool>;
      for (final word in searchWords(query ?? '')) {
        where = where & t.searchText.like('%${_escapeLike(word)}%');
      }
      if (groupIds != null && groupIds.isNotEmpty) {
        where = where & t.groupId.isIn(groupIds);
      }
      if (supplierId != null) where = where & t.supplierId.equals(supplierId);
      return where;
    }

    final total =
        await (_db.selectOnly(_db.cachedGoods)
              ..addColumns([_db.cachedGoods.id.count()])
              ..where(predicate(_db.cachedGoods)))
            .map((row) => row.read(_db.cachedGoods.id.count()) ?? 0)
            .getSingle();

    final rows =
        await (_db.select(_db.cachedGoods)
              ..where(predicate)
              ..orderBy([(t) => OrderingTerm(expression: t.name)])
              ..limit(limit, offset: offset))
            .get();

    return Paged<Good>(
      items: rows.map(_toGood).toList(),
      total: total,
      limit: limit,
      offset: offset,
    );
  }

  /// Товар по идентификатору; `null` — нет в кэше.
  Future<Good?> goodById(String id) async {
    final row = await (_db.select(
      _db.cachedGoods,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toGood(row);
  }

  /// Товар по штрихкоду; `null` — ШК не привязан ни к одному товару в кэше.
  Future<Good?> goodByBarcode(String barcode) async {
    final link = await (_db.select(
      _db.cachedBarcodes,
    )..where((t) => t.barcode.equals(barcode))).getSingleOrNull();
    return link == null ? null : goodById(link.goodId);
  }

  /// Все штрихкоды товара.
  Future<List<Barcode>> barcodesOfGood(String goodId) async {
    final rows = await (_db.select(
      _db.cachedBarcodes,
    )..where((t) => t.goodId.equals(goodId))).get();
    return rows
        .map((r) => Barcode(barcode: r.barcode, symbology: r.symbology))
        .toList();
  }

  /// Всё дерево групп.
  Future<List<NomenclatureGroup>> groups() async {
    final rows = await (_db.select(
      _db.cachedGroups,
    )..orderBy([(t) => OrderingTerm(expression: t.name)])).get();
    return rows
        .map(
          (r) => NomenclatureGroup(
            id: r.id,
            code: r.code,
            name: r.name,
            parentId: r.parentId,
          ),
        )
        .toList();
  }

  /// Поставщики, при непустом [query] — по вхождению в название.
  Future<List<Supplier>> suppliers({String? query}) async {
    final select = _db.select(_db.cachedSuppliers)
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    final rows = await select.get();
    final needle = normalizeSearchText(query ?? '').trim();
    final filtered = needle.isEmpty
        ? rows
        : rows.where((r) => normalizeSearchText(r.name).contains(needle));
    return filtered.map((r) => Supplier(id: r.id, name: r.name)).toList();
  }

  /// Ячейки склада: [query] — вхождение в адрес, [isFloor] — только напольные/неновопольные.
  Future<List<Cell>> cells({
    String? query,
    String? warehouseId,
    bool? isFloor,
  }) async {
    final select = _db.select(_db.cachedCells)
      ..orderBy([(t) => OrderingTerm(expression: t.address)]);
    if (warehouseId != null) {
      select.where((t) => t.warehouseId.equals(warehouseId));
    }
    if (isFloor != null) select.where((t) => t.isFloor.equals(isFloor));
    final needle = (query ?? '').trim().toLowerCase();
    if (needle.isNotEmpty) {
      select.where((t) => t.addressLower.like('%${_escapeLike(needle)}%'));
    }
    final rows = await select.get();
    return rows.map(_toCell).toList();
  }

  //* --- вспомогательное --- *//

  /// Идентификаторы группы и всех её потомков.
  ///
  /// Зачем: выбор родительской группы должен показывать товары из вложенных, иначе фильтр по
  /// верхнему уровню даёт пусто. На сервере это рекурсивный CTE (P1-07), здесь — обход дерева
  /// в памяти: групп немного, и грузятся они всё равно целиком.
  static List<String> descendantGroupIds(
    List<NomenclatureGroup> all,
    String rootId,
  ) {
    final children = <String, List<String>>{};
    for (final g in all) {
      final parent = g.parentId;
      if (parent != null) (children[parent] ??= []).add(g.id);
    }
    final result = <String>[rootId];
    final queue = <String>[rootId];
    while (queue.isNotEmpty) {
      final next = children[queue.removeLast()] ?? const [];
      result.addAll(next);
      queue.addAll(next);
    }
    return result;
  }

  /// Экранирование спецсимволов LIKE: без него код с `%` или `_` превращался бы в шаблон
  /// и находил лишнее.
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  Good _toGood(CachedGood r) => Good(
    id: r.id,
    code: r.code,
    name: r.name,
    fullName: r.fullName,
    uom: r.uom,
    groupId: r.groupId,
    groupName: r.groupName,
    supplierId: r.supplierId,
    supplierName: r.supplierName,
    isActive: r.isActive,
  );

  Cell _toCell(CachedCell r) => Cell(
    id: r.id,
    warehouseId: r.warehouseId,
    address: r.address,
    type: r.type,
    isFloor: r.isFloor,
    isActive: r.isActive,
  );
}
