import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/search_text.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../contents/domain/stock_entities.dart';
import '../../data/catalog_cache.dart';
import '../../data/catalog_models.dart';
import 'goods_list_cubit.dart';

/// Вкладка «Товары» в «Остатках» (ADHOC-33): товары, которые есть на складе, с количеством.
///
/// Что: тот же список с поиском и фильтрами, что у «Номенклатуры» ([GoodsListCubit]), но
///      источник - снимок склада со своей очередью поверх, а не справочник: в списке только
///      товары с остатком больше нуля, у строки - общее количество.
/// Зачем: раздел называется «Остатки», а показывал справочник без остатков; работает и без
///        связи - снимок лежит на терминале.
/// Как: при открытии снимок обновляется с сервера (как во вкладке «Короба»), дальше поиск,
///      группа, поставщик и склады отбираются в памяти - на масштабе пилота это сотни строк.
///      Склады - фильтром с множественным выбором, по умолчанию все.
@injectable
class StockGoodsCubit extends GoodsListCubit {
  StockGoodsCubit(
    super.catalog,
    this._contents,
    this._snapshot,
    this._warehouses,
  ) {
    // Снимок обновился по любому поводу (очередь, версии данных - ADHOC-60) - список
    // перечитывается из кэша, без второй загрузки.
    _updates = _snapshot.updated.listen((_) {
      if (state.status == GoodsListStatus.loaded) unawaited(_read());
    });
  }

  late final StreamSubscription<void> _updates;

  final ContentsRepository _contents;
  final ContentsSnapshotSync _snapshot;
  final InternalWarehouses _warehouses;

  /// Чем кончилось последнее обновление снимка; `null` - обновился (см. `BoxesCubit`).
  Failure? _refreshFailure;

  /// Остатки из снимка - отбираются заново при каждой смене поиска или фильтра.
  List<GoodStock> _all = const [];

  /// Товары остатков из справочника терминала (ADHOC-59): карточка открывается с товаром
  /// целиком - с признаком «маркируемый», полным наименованием, поставщиком.
  Map<String, Good> _catalogGoods = const {};

  @override
  Future<void> init() async {
    emit(state.copyWith(warehouses: await _warehouses.all()));
    await reload();
    // Справочники фильтров - после списка: остатки кладовщику нужнее, чем варианты фильтра.
    final groups = await catalog.listGroups();
    final suppliers = await catalog.listSuppliers();
    if (isClosed) return;
    emit(
      state.copyWith(
        groups: groups.fold((_) => const [], (g) => g),
        suppliers: suppliers.fold((_) => const [], (s) => s),
      ),
    );
  }

  /// «Потянуть вниз» и «повторить» в «Остатках» - с обновлением снимка.
  @override
  Future<void> refresh() => reload();

  /// Обновить снимок с сервера и перечитать остатки.
  Future<void> reload() async {
    emit(state.copyWith(status: GoodsListStatus.loading, failure: null));
    final res = await _snapshot.refresh();
    _refreshFailure = res.isLeft ? res.left : null;
    if (isClosed) return;
    await _read();
  }

  /// Карточка обновила снимок - перечитать его, не обращаясь к серверу.
  @override
  Future<void> returnedFromCard(String goodId) => _read();

  /// Перечитать остатки из снимка, не обращаясь к серверу.
  Future<void> _read() async {
    if (isClosed) return;
    final viewed = await _contents.goodsStock(refreshFailure: _refreshFailure);
    _all = viewed.value ?? const [];
    _catalogGoods = await catalog.goodsByIds(_all.map((s) => s.goodId));
    if (isClosed) return;
    emit(state.copyWith(freshness: viewed.freshness));
    await load();
  }

  /// Отбор остатков под поиск и фильтры - в памяти, без сети.
  @override
  Future<void> load() async {
    final words = searchWords(state.query ?? '');
    final groupId = state.groupId;
    final groups = groupId == null
        ? null
        : CatalogCache.descendantGroupIds(state.groups, groupId).toSet();
    final qty = <String, double>{};
    final goods = <Good>[];
    for (final s in _all) {
      if (groups != null && !groups.contains(s.groupId)) continue;
      if (state.supplierId != null && s.supplierId != state.supplierId) {
        continue;
      }
      final text = normalizeSearchText('${s.name ?? ''} ${s.code ?? ''}');
      if (!words.every(text.contains)) continue;
      final q = s.qtyOn(state.warehouseIds);
      if (q <= 0) continue;
      qty[s.goodId] = q;
      goods.add(_good(s));
    }
    emit(
      state.copyWith(
        status: GoodsListStatus.loaded,
        loadingMore: false,
        goods: goods,
        total: goods.length,
        stockQty: qty,
        pendingGoods: {
          for (final s in _all)
            if (s.pending) s.goodId,
        },
      ),
    );
  }

  @override
  Future<void> close() {
    _updates.cancel();
    return super.close();
  }

  /// Подгрузки нет: список целиком в памяти.
  @override
  Future<void> loadMore() async {}

  /// Строка остатков как товар - список и карточка работают с [Good].
  ///
  /// Товар берётся из справочника терминала целиком (ADHOC-59): собранный из строки снимка, он
  /// терял признак «маркируемый», и карточка из «Остатков» показывала любой маркируемый товар
  /// «Без марки» - а по признаку блок «Штрихкоды» решает, проверять ли марки перед отвязкой ШК.
  /// Товара нет в справочнике - карточка всё равно откроется с тем, что известно: остатки и ШК
  /// она читает по идентификатору.
  Good _good(GoodStock s) => _catalogGoods[s.goodId] ?? _fromStock(s);

  static Good _fromStock(GoodStock s) => Good(
    id: s.goodId,
    code: s.code,
    name: s.name ?? '',
    uom: s.uom ?? '',
    groupId: s.groupId,
    groupName: s.groupName,
    supplierId: s.supplierId,
  );
}
