import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/warehouse/internal_warehouses.dart';
import '../../stock/data/catalog_cache.dart';
import '../domain/contents_entities.dart';
import '../domain/contents_repository.dart';
import '../domain/stock_entities.dart';
import 'contents_api.dart';
import 'contents_cache.dart';
import 'pending_overlay.dart';

/// Содержимое ячеек и коробов: сервер → снимок → свои операции поверх (P5-05).
///
/// Порядок источников:
/// 1. Сервер с коротким таймаутом - со связью данные точные.
/// 2. Нет связи - снимок на терминале с моментом, на который он согласован.
/// 3. Поверх обоих - свои неотправленные приёмки и размещения ([PendingOverlay]): сервер
///    о них ещё не знает, снимок тем более.
///
/// Наименования товаров и адреса ячеек, которых нет в снимке и в операциях, подставляются
/// из справочников терминала. Склады (P6-07-2) приводятся к соглашению терминала
/// («Основной» - `null`) до наложения очереди и подписываются по справочнику складов.
@LazySingleton(as: ContentsRepository)
class ContentsRepositoryImpl implements ContentsRepository {
  ContentsRepositoryImpl(
    this._api,
    this._cache,
    this._catalog,
    this._outbox,
    this._warehouses,
  );

  final ContentsApi _api;
  final ContentsCache _cache;
  final CatalogCache _catalog;
  final OutboxRepository _outbox;
  final InternalWarehouses _warehouses;

  /// Сколько операций очереди просматривать. Неотправленных приёмок и размещений на терминале
  /// единицы; предел - только защита от разбора тысяч привязок ШК.
  static const _queueLimit = 1000;

  @override
  Future<Either<Failure, Viewed<LoadUnitView>>> loadUnit(String id) async {
    final overlay = await _overlay();
    final res = await _api.card(id);

    LoadUnitView? base;
    DataFreshness freshness;
    if (res.isRight) {
      base = res.right;
      freshness = const FreshFromServer();
    } else if (_isNotFound(res.left)) {
      freshness = const FreshFromServer();
    } else if (res.left is NetworkFailure) {
      final asOf = await _cache.asOf();
      // Показать нечего вовсе: снимка не было, и свои операции короб не упоминают.
      if (asOf == null && !overlay.referencedLoadUnits.contains(id)) {
        return Left(res.left);
      }
      base = (await _cache.loadUnits([id]))[id];
      freshness = FromSnapshot(asOf);
    } else {
      return Left(res.left);
    }

    final view = overlay.applyToLoadUnit(id, _unit(base, overlay.cells));
    return Right(
      Viewed(
        view == null ? null : await _named(view, overlay.cells),
        freshness,
      ),
    );
  }

  @override
  Future<String?> cachedLoadUnitCell(String id) async {
    final overlay = await _overlay();
    final base = (await _cache.loadUnits([id]))[id];
    return overlay.applyToLoadUnit(id, _unit(base, overlay.cells))?.cellAddress;
  }

  @override
  Future<LoadUnitView?> cachedLoadUnit(String id) async {
    final overlay = await _overlay();
    final base = (await _cache.loadUnits([id]))[id];
    return overlay.applyToLoadUnit(id, _unit(base, overlay.cells));
  }

  @override
  Future<List<StockMark>> marksByCode(String code) async {
    final overlay = await _overlay();
    final def = overlay.cells.defaultInternalWarehouse;
    final base = {
      for (final m in await _cache.marksByCode(code))
        m.cis: m.cellId == null
            ? m
            : StockMark(
                cis: m.cis,
                goodId: m.goodId,
                productionDate: m.productionDate,
                cellId: m.cellId,
                internalWarehouseId: InternalWarehouses.normalize(
                  m.internalWarehouseId,
                  def,
                ),
                aggregateCode: m.aggregateCode,
              ),
    };
    // Короба марок и операций - с наложенной очередью: марка, вынутая из короба, ложится
    // в его ячейку и склад.
    final boxes = overlay.applyToAll(
      _units(
        await _cache.loadUnits({
          ...overlay.referencedLoadUnits,
          for (final m in base.values) ?m.loadUnitId,
        }),
        overlay.cells,
      ),
    );
    return overlay.applyToMarks(base, code, boxes: boxes).values.toList();
  }

  @override
  Future<Either<Failure, String?>> loadUnitIdByCzCode(String czCode) async {
    final overlay = await _overlay();
    final res = await _api.cardByCzCode(czCode);
    if (res.isRight) return Right(res.right.id);
    // Короб своей неотправленной приёмки сервер ещё не знает, снимок - тем более.
    final own = overlay.loadUnitIdByCzCode(czCode);
    if (_isNotFound(res.left)) return Right(own);
    if (res.left is! NetworkFailure) return Left(res.left);
    final cached = await _cache.loadUnitIdByCzCode(czCode);
    if (cached != null || own != null) return Right(cached ?? own);
    return await _cache.asOf() == null ? Left(res.left) : const Right(null);
  }

  @override
  Future<Either<Failure, Viewed<CellView>>> cell(CellRef cell) async {
    final overlay = await _overlay();
    final res = await _api.cell(cell.id);

    CellView base;
    DataFreshness freshness;
    if (res.isRight) {
      base = res.right;
      freshness = const FreshFromServer();
    } else if (res.left is NetworkFailure) {
      final asOf = await _cache.asOf();
      if (asOf == null && overlay.ops.isEmpty) return Left(res.left);
      base = CellView(
        cellId: cell.id,
        address: cell.address,
        loadUnits: await _cache.loadUnitsInCell(cell.id),
        loose: await _cache.looseInCell(cell.id),
      );
      freshness = FromSnapshot(asOf);
    } else {
      return Left(res.left);
    }

    final known = _units(
      await _cache.loadUnits(overlay.referencedLoadUnits),
      overlay.cells,
    );
    final def = overlay.cells.defaultInternalWarehouse;
    final view = overlay.applyToCell(
      CellView(
        cellId: base.cellId,
        address: base.address,
        loadUnits: [for (final lu in base.loadUnits) _unit(lu, overlay.cells)!],
        loose: [
          for (final l in base.loose)
            l.onWarehouse(
              InternalWarehouses.normalize(l.internalWarehouseId, def),
            ),
        ],
      ),
      known,
    );
    return Right(
      Viewed(
        CellView(
          cellId: view.cellId,
          address: view.address,
          loadUnits: [
            for (final lu in view.loadUnits) await _named(lu, overlay.cells),
          ],
          loose: await _namedLines(view.loose, await _warehouseNames()),
        ),
        freshness,
      ),
    );
  }

  @override
  Future<CellRef?> findCell(String address) async {
    final needle = address.trim().toLowerCase();
    // Справочник ищет по вхождению - точный адрес отбираем здесь: «A-1-1» не должен открыть
    // «A-1-10».
    final found = await _catalog.cells(query: needle);
    for (final c in found) {
      if (c.address.toLowerCase() == needle) {
        return CellRef(id: c.id, address: c.address);
      }
    }
    return null;
  }

  @override
  Future<Viewed<List<LoadUnitView>>> loadUnits({
    Failure? refreshFailure,
  }) async {
    final overlay = await _overlay();
    final all = overlay.applyToAll(
      _units(await _cache.allLoadUnits(), overlay.cells),
    );
    return Viewed(
      await _sorted(all.values, overlay.cells),
      await _freshness(refreshFailure),
    );
  }

  @override
  Future<Either<Failure, Viewed<List<LoadUnitView>>>> searchLoadUnits(
    String code,
  ) async {
    final overlay = await _overlay();
    final res = await _api.search(code);

    Map<String, LoadUnitView> base;
    DataFreshness freshness;
    if (res.isRight) {
      base = {for (final lu in res.right) lu.id: lu};
      freshness = const FreshFromServer();
    } else if (res.left is AuthFailure) {
      return Left(res.left);
    } else {
      // Не только обрыв связи: сервер без этой ручки (старая версия) или со сбоем отвечает
      // кодом, а короба на терминале уже есть. Поиск - удобство поверх снимка, и отказывать
      // в нём, когда снимок под рукой, хуже, чем искать по снимку с подписью «данные на».
      // Найдено на DT50S: прод ещё без ручки поиска, а кэш с коробами был.
      base = await _cache.allLoadUnits();
      freshness = FromSnapshot(
        await _cache.asOf(),
        offline: res.left is NetworkFailure,
      );
    }

    // Короба своих неотправленных приёмок сервер ещё не знает - наложение их добавляет,
    // поэтому отбор по коду идёт уже после него.
    final found = overlay
        .applyToAll(_units(base, overlay.cells))
        .values
        .where((lu) => matchesShortCode(lu.id, code));
    return Right(Viewed(await _sorted(found, overlay.cells), freshness));
  }

  @override
  Future<Either<Failure, LoadUnitHistory>> history(String id) =>
      _api.history(id);

  @override
  Future<Viewed<List<GoodStock>>> goodsStock({Failure? refreshFailure}) async {
    final qty = <String, Map<String?, double>>{};
    final pending = <String>{};
    for (final p in await _places()) {
      final byWarehouse = qty.putIfAbsent(p.goodId, () => {});
      byWarehouse[p.internalWarehouseId] =
          (byWarehouse[p.internalWarehouseId] ?? 0) + p.qty;
      if (p.pending) pending.add(p.goodId);
    }
    final goods = await _catalog.goodsByIds(qty.keys);
    final out = [
      for (final e in qty.entries)
        GoodStock(
          goodId: e.key,
          name: goods[e.key]?.name,
          code: goods[e.key]?.code,
          uom: goods[e.key]?.uom,
          groupId: goods[e.key]?.groupId,
          groupName: goods[e.key]?.groupName,
          supplierId: goods[e.key]?.supplierId,
          byWarehouse: e.value,
          pending: pending.contains(e.key),
        ),
    ]..sort((a, b) => (a.name ?? '\uffff').compareTo(b.name ?? '\uffff'));
    return Viewed(out, await _freshness(refreshFailure));
  }

  @override
  Future<Viewed<List<StockPlace>>> goodPlaces(
    String goodId, {
    Failure? refreshFailure,
  }) async {
    final places = await _places(goodId: goodId);
    // Вдоль стеллажа: по адресу ячейки, в ячейке - россыпь, затем короба; внутри - по партии.
    places.sort((a, b) {
      final byCell = (a.cellAddress ?? '\uffff').compareTo(
        b.cellAddress ?? '\uffff',
      );
      if (byCell != 0) return byCell;
      final byBox = (a.loadUnitId ?? '').compareTo(b.loadUnitId ?? '');
      if (byBox != 0) return byBox;
      return _batchKey(a.productionDate).compareTo(_batchKey(b.productionDate));
    });
    return Viewed(places, await _freshness(refreshFailure));
  }

  /// Все места товара на складе (ADHOC-33): россыпь всех ячеек и содержимое живых коробов из
  /// снимка, своя очередь поверх; [goodId] - только этого товара. Нулевых строк нет.
  Future<List<StockPlace>> _places({String? goodId}) async {
    final overlay = await _overlay();
    final def = overlay.cells.defaultInternalWarehouse;
    final loose = {
      for (final e in (await _cache.allLoose()).entries)
        e.key: [
          for (final l in e.value)
            l.onWarehouse(
              InternalWarehouses.normalize(l.internalWarehouseId, def),
            ),
        ],
    };
    final boxes = overlay.applyToWarehouse(
      _units(await _cache.allLoadUnits(), overlay.cells),
      loose,
    );
    final names = await _warehouseNames();
    StockPlace place(String cell, ContentLine l, {String? box}) => StockPlace(
      goodId: l.goodId,
      cellId: cell,
      cellAddress: overlay.cells.addressById[cell],
      loadUnitId: box,
      productionDate: l.productionDate,
      qty: l.qty,
      internalWarehouseId: l.internalWarehouseId,
      internalWarehouseName: names[l.internalWarehouseId],
      pending: l.pending,
    );
    bool wanted(ContentLine l) =>
        l.qty > 0 && (goodId == null || l.goodId == goodId);
    return [
      for (final lu in boxes.values)
        if (lu.live && lu.cellId != null)
          for (final l in lu.lines)
            if (wanted(l)) place(lu.cellId!, l, box: lu.id),
      for (final e in loose.entries)
        for (final l in e.value)
          if (wanted(l)) place(e.key, l),
    ];
  }

  /// Откуда данные списка из снимка: [refreshFailure] `null` - снимок только что обновлён.
  Future<DataFreshness> _freshness(Failure? refreshFailure) async =>
      refreshFailure == null
      ? const FreshFromServer()
      : FromSnapshot(
          await _cache.asOf(),
          offline: refreshFailure is NetworkFailure,
        );

  /// Дата партии DD-MM-YYYY как ключ сортировки YYYYMMDD.
  static String _batchKey(String date) {
    final p = date.split('-');
    return p.length == 3 ? '${p[2]}${p[1]}${p[0]}' : date;
  }

  /// Короба с наименованиями и адресами - живые первыми, затем по адресу ячейки и времени
  /// создания: так кладовщик идёт вдоль стеллажа.
  Future<List<LoadUnitView>> _sorted(
    Iterable<LoadUnitView> units,
    OverlayCells cells,
  ) async {
    final named = [for (final lu in units) await _named(lu, cells)];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    named.sort((a, b) {
      if (a.live != b.live) return a.live ? -1 : 1;
      final byCell = (a.cellAddress ?? '\uffff').compareTo(
        b.cellAddress ?? '\uffff',
      );
      if (byCell != 0) return byCell;
      return (a.createdAt ?? epoch).compareTo(b.createdAt ?? epoch);
    });
    return named;
  }

  /// Свои неотправленные приёмки и размещения вместе с ячейками, нужными для наложения.
  Future<PendingOverlay> _overlay() async {
    final ops = await _outbox.pending(limit: _queueLimit);
    final cells = await _catalog.cells();
    return PendingOverlay(
      ops,
      OverlayCells(
        defaultInternalWarehouse: await _warehouses.defaultId(),
        addressById: {for (final c in cells) c.id: c.address},
        defaultCellByWarehouse: {
          for (final c in cells)
            if (c.isDefault) c.warehouseId: c.id,
        },
      ),
    );
  }

  /// Короб со складом в соглашении терминала: «Основной» - `null`; строки - склада короба.
  LoadUnitView? _unit(LoadUnitView? lu, OverlayCells cells) {
    if (lu == null) return null;
    final id = InternalWarehouses.normalize(
      lu.internalWarehouseId,
      cells.defaultInternalWarehouse,
    );
    return id == lu.internalWarehouseId &&
            lu.lines.every((l) => l.internalWarehouseId == id)
        ? lu
        : lu.onWarehouse(id);
  }

  Map<String, LoadUnitView> _units(
    Map<String, LoadUnitView> units,
    OverlayCells cells,
  ) => units.map((id, lu) => MapEntry(id, _unit(lu, cells)!));

  /// Имена складов, кроме «Основного», - для подписи помеченного товара.
  Future<Map<String, String>> _warehouseNames() async => {
    for (final w in await _warehouses.all())
      if (!w.isDefault) w.id: w.name,
  };

  /// Короб с наименованиями товаров, адресом ячейки и именем склада из справочников.
  Future<LoadUnitView> _named(LoadUnitView lu, OverlayCells cells) async {
    final names = await _warehouseNames();
    return lu.copyWith(
      cellAddress: lu.cellAddress ?? cells.addressById[lu.cellId],
      lines: await _namedLines(lu.lines, names),
      internalWarehouseName: names[lu.internalWarehouseId],
    );
  }

  Future<List<ContentLine>> _namedLines(
    List<ContentLine> lines,
    Map<String, String> warehouses,
  ) async => [
    for (final l in lines)
      await _namedLine(l).then(
        (n) => n.copyWith(
          internalWarehouseName: warehouses[n.internalWarehouseId],
        ),
      ),
  ];

  Future<ContentLine> _namedLine(ContentLine l) async {
    if (l.goodName != null) return l;
    final g = await _catalog.goodById(l.goodId);
    return g == null
        ? l
        : l.copyWith(goodName: g.name, goodCode: g.code, uom: g.uom);
  }

  static bool _isNotFound(Failure f) =>
      f is ServerFailure && f.statusCode == 404;
}
