import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../domain/contents_entities.dart';
import 'contents_dto.dart';

/// Снимок содержимого склада в локальной базе (P5-05).
///
/// Что: живые короба, их содержимое и россыпь по ячейкам — то, что пришло последним снимком.
/// Как: запись — полная замена в одной транзакции, как у справочников: сервер отдаёт только
/// живые короба, и выведенные из обращения иначе остались бы здесь навсегда; обрыв посреди
/// записи оставляет прежний снимок целиком. Наименований товаров здесь нет — их даёт
/// справочник товаров терминала.
@lazySingleton
class ContentsCache {
  ContentsCache(this._db);

  final AppDatabase _db;

  /// Имя отметки о загрузке в `CatalogSyncMarks`. В список справочников (`CatalogName.all`)
  /// не входит: готовность «Остатков» от снимка не зависит.
  static const markName = 'contents';

  /// Заменить снимок целиком. Отметка — момент снимка на сервере, а не время загрузки:
  /// кладовщику важно, на когда данные, а не когда их скачали.
  Future<void> replace(ContentsSnapshot snapshot) => _db.transaction(() async {
    await _db.delete(_db.cachedLoadUnits).go();
    await _db.delete(_db.cachedLoadUnitLines).go();
    await _db.delete(_db.cachedLooseStock).go();
    await _db.delete(_db.cachedCzMarks).go();
    await _db.batch((b) {
      b.insertAll(_db.cachedLoadUnits, [
        for (final lu in snapshot.loadUnits)
          CachedLoadUnitsCompanion.insert(
            id: lu.id,
            kind: lu.kind,
            cellId: lu.cellId,
            createdAt: lu.createdAt,
            internalWarehouseId: Value(lu.internalWarehouseId),
            czCode: Value(lu.czCode),
            czOpened: Value(lu.czOpened),
          ),
      ]);
      b.insertAll(_db.cachedLoadUnitLines, [
        for (final lu in snapshot.loadUnits)
          for (final l in lu.lines)
            CachedLoadUnitLinesCompanion.insert(
              loadUnitId: lu.id,
              goodId: l.goodId,
              batchId: l.batchId,
              productionDate: l.productionDate,
              qty: l.qty,
            ),
      ]);
      b.insertAll(_db.cachedLooseStock, [
        for (final l in snapshot.loose)
          CachedLooseStockCompanion.insert(
            cellId: l.cellId,
            internalWarehouseId: l.internalWarehouseId,
            goodId: l.line.goodId,
            batchId: l.line.batchId,
            productionDate: l.line.productionDate,
            qty: l.line.qty,
          ),
      ]);
      b.insertAll(_db.cachedCzMarks, [
        for (final m in snapshot.marks)
          CachedCzMarksCompanion.insert(
            cis: m.cis,
            goodId: m.goodId,
            batchId: m.batchId,
            productionDate: m.productionDate,
            loadUnitId: Value(m.loadUnitId),
            cellId: Value(m.cellId),
            internalWarehouseId: Value(m.internalWarehouseId),
            aggregateCode: Value(m.aggregateCode),
          ),
      ]);
    });
    await _db
        .into(_db.catalogSyncMarks)
        .insertOnConflictUpdate(
          CatalogSyncMarksCompanion.insert(
            catalog: markName,
            syncedAt: snapshot.asOf,
          ),
        );
  });

  /// На какой момент снимок; `null` — снимка ещё не было.
  Future<DateTime?> asOf() async {
    final row = await (_db.select(
      _db.catalogSyncMarks,
    )..where((t) => t.catalog.equals(markName))).getSingleOrNull();
    return row?.syncedAt;
  }

  /// Короба снимка по идентификаторам, с содержимым. Наименований и адресов нет — их
  /// подставляет репозиторий из справочников.
  Future<Map<String, LoadUnitView>> loadUnits(Iterable<String> ids) async {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return {};
    final rows = await (_db.select(
      _db.cachedLoadUnits,
    )..where((t) => t.id.isIn(wanted))).get();
    return _withLines(rows);
  }

  /// Все короба снимка (P5-05-1) — для вкладки «Короба» и поиска без связи. Целиком, без
  /// страниц: на масштабе пилота это сотни строк, а список на экране строится лениво.
  Future<Map<String, LoadUnitView>> allLoadUnits() async =>
      _withLines(await _db.select(_db.cachedLoadUnits).get());

  /// Короб снимка с кодом короба ЧЗ [czCode] (`00`+SSCC, CZ-06); `null` — такого нет.
  Future<String?> loadUnitIdByCzCode(String czCode) async {
    final row = await (_db.select(
      _db.cachedLoadUnits,
    )..where((t) => t.czCode.equals(czCode))).getSingleOrNull();
    return row?.id;
  }

  /// Марки снимка по коду (CZ-06): марка с этим КИ или марки упаковки с этим кодом. Склад —
  /// как прислал сервер; к соглашению терминала его приводит репозиторий.
  Future<List<StockMark>> marksByCode(String code) async {
    final rows = await (_db.select(
      _db.cachedCzMarks,
    )..where((t) => t.cis.equals(code) | t.aggregateCode.equals(code))).get();
    return [
      for (final r in rows)
        StockMark(
          cis: r.cis,
          goodId: r.goodId,
          productionDate: r.productionDate,
          loadUnitId: r.loadUnitId,
          cellId: r.cellId,
          internalWarehouseId: r.internalWarehouseId,
          aggregateCode: r.aggregateCode,
        ),
    ];
  }

  /// Короба снимка в ячейке.
  Future<List<LoadUnitView>> loadUnitsInCell(String cellId) async {
    final rows =
        await (_db.select(_db.cachedLoadUnits)
              ..where((t) => t.cellId.equals(cellId))
              ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
            .get();
    return (await _withLines(rows)).values.toList();
  }

  /// Россыпь снимка в ячейке. Строки разных внутренних складов — разные строки (P6-07-2):
  /// брак рядом с основным товаром показывается и перемещается отдельно.
  Future<List<ContentLine>> looseInCell(String cellId) async {
    final rows = await (_db.select(
      _db.cachedLooseStock,
    )..where((t) => t.cellId.equals(cellId))).get();
    final out = <ContentLine>[];
    for (final r in rows) {
      final line = ContentLine(
        goodId: r.goodId,
        productionDate: r.productionDate,
        qty: r.qty,
        internalWarehouseId: r.internalWarehouseId,
      );
      final i = out.indexWhere(line.sameBatch);
      if (i < 0) {
        out.add(line);
      } else {
        out[i] = out[i].copyWith(qty: out[i].qty + line.qty);
      }
    }
    return out;
  }

  /// Россыпь снимка по всем ячейкам (ADHOC-33) — для остатков по товарам.
  Future<Map<String, List<ContentLine>>> allLoose() async {
    final out = <String, List<ContentLine>>{};
    for (final r in await _db.select(_db.cachedLooseStock).get()) {
      final lines = out.putIfAbsent(r.cellId, () => []);
      final line = ContentLine(
        goodId: r.goodId,
        productionDate: r.productionDate,
        qty: r.qty,
        internalWarehouseId: r.internalWarehouseId,
      );
      final i = lines.indexWhere(line.sameBatch);
      if (i < 0) {
        lines.add(line);
      } else {
        lines[i] = lines[i].copyWith(qty: lines[i].qty + line.qty);
      }
    }
    return out;
  }

  /// Короба со строками содержимого; порядок — как у [rows].
  Future<Map<String, LoadUnitView>> _withLines(
    List<CachedLoadUnit> rows,
  ) async {
    if (rows.isEmpty) return {};
    final lines = await (_db.select(
      _db.cachedLoadUnitLines,
    )..where((t) => t.loadUnitId.isIn(rows.map((r) => r.id)))).get();
    final warehouseOf = {for (final r in rows) r.id: r.internalWarehouseId};
    final byUnit = <String, List<ContentLine>>{};
    for (final l in lines) {
      byUnit
          .putIfAbsent(l.loadUnitId, () => [])
          .add(
            ContentLine(
              goodId: l.goodId,
              productionDate: l.productionDate,
              qty: l.qty,
              internalWarehouseId: warehouseOf[l.loadUnitId],
            ),
          );
    }
    return {
      for (final r in rows)
        r.id: LoadUnitView(
          id: r.id,
          kind: r.kind,
          cellId: r.cellId,
          createdAt: r.createdAt.toLocal(),
          // В снимке только живые короба.
          live: true,
          internalWarehouseId: r.internalWarehouseId,
          czCode: r.czCode,
          czOpened: r.czOpened,
          lines: byUnit[r.id] ?? const [],
        ),
    };
  }
}
