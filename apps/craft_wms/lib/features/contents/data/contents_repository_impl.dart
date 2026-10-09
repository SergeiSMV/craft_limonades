import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../stock/data/catalog_cache.dart';
import '../domain/contents_entities.dart';
import '../domain/contents_repository.dart';
import 'contents_api.dart';
import 'contents_cache.dart';
import 'pending_overlay.dart';

/// Содержимое ячеек и коробов: сервер → снимок → свои операции поверх (P5-05).
///
/// Порядок источников:
/// 1. Сервер с коротким таймаутом — со связью данные точные.
/// 2. Нет связи — снимок на терминале с моментом, на который он согласован.
/// 3. Поверх обоих — свои неотправленные приёмки и размещения ([PendingOverlay]): сервер
///    о них ещё не знает, снимок тем более.
///
/// Наименования товаров и адреса ячеек, которых нет в снимке и в операциях, подставляются
/// из справочников терминала.
@LazySingleton(as: ContentsRepository)
class ContentsRepositoryImpl implements ContentsRepository {
  ContentsRepositoryImpl(this._api, this._cache, this._catalog, this._outbox);

  final ContentsApi _api;
  final ContentsCache _cache;
  final CatalogCache _catalog;
  final OutboxRepository _outbox;

  /// Сколько операций очереди просматривать. Неотправленных приёмок и размещений на терминале
  /// единицы; предел — только защита от разбора тысяч привязок ШК.
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

    final view = overlay.applyToLoadUnit(id, base);
    return Right(
      Viewed(
        view == null ? null : await _named(view, overlay.cells),
        freshness,
      ),
    );
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

    final known = await _cache.loadUnits(overlay.referencedLoadUnits);
    final view = overlay.applyToCell(base, known);
    return Right(
      Viewed(
        CellView(
          cellId: view.cellId,
          address: view.address,
          loadUnits: [
            for (final lu in view.loadUnits) await _named(lu, overlay.cells),
          ],
          loose: await _namedLines(view.loose),
        ),
        freshness,
      ),
    );
  }

  @override
  Future<CellRef?> findCell(String address) async {
    final needle = address.trim().toLowerCase();
    // Справочник ищет по вхождению — точный адрес отбираем здесь: «A-1-1» не должен открыть
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
    final all = overlay.applyToAll(await _cache.allLoadUnits());
    final freshness = refreshFailure == null
        ? const FreshFromServer()
        : FromSnapshot(
            await _cache.asOf(),
            offline: refreshFailure is NetworkFailure,
          );
    return Viewed(await _sorted(all.values, overlay.cells), freshness);
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
      // кодом, а короба на терминале уже есть. Поиск — удобство поверх снимка, и отказывать
      // в нём, когда снимок под рукой, хуже, чем искать по снимку с подписью «данные на».
      // Найдено на DT50S: прод ещё без ручки поиска, а кэш с коробами был.
      base = await _cache.allLoadUnits();
      freshness = FromSnapshot(
        await _cache.asOf(),
        offline: res.left is NetworkFailure,
      );
    }

    // Короба своих неотправленных приёмок сервер ещё не знает — наложение их добавляет,
    // поэтому отбор по коду идёт уже после него.
    final found = overlay
        .applyToAll(base)
        .values
        .where((lu) => matchesShortCode(lu.id, code));
    return Right(Viewed(await _sorted(found, overlay.cells), freshness));
  }

  @override
  Future<Either<Failure, LoadUnitHistory>> history(String id) =>
      _api.history(id);

  /// Короба с наименованиями и адресами — живые первыми, затем по адресу ячейки и времени
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
        addressById: {for (final c in cells) c.id: c.address},
        defaultCellByWarehouse: {
          for (final c in cells)
            if (c.isDefault) c.warehouseId: c.id,
        },
      ),
    );
  }

  /// Короб с наименованиями товаров и адресом ячейки из справочников, где их нет.
  Future<LoadUnitView> _named(LoadUnitView lu, OverlayCells cells) async =>
      lu.copyWith(
        cellAddress: lu.cellAddress ?? cells.addressById[lu.cellId],
        lines: await _namedLines(lu.lines),
      );

  Future<List<ContentLine>> _namedLines(List<ContentLine> lines) async => [
    for (final l in lines)
      if (l.goodName != null)
        l
      else
        await _catalog
            .goodById(l.goodId)
            .then(
              (g) => g == null
                  ? l
                  : l.copyWith(goodName: g.name, goodCode: g.code, uom: g.uom),
            ),
  ];

  static bool _isNotFound(Failure f) =>
      f is ServerFailure && f.statusCode == 404;
}
