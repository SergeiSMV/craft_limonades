import 'dart:async';

import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../data/catalog_models.dart';
import '../../data/catalog_repository.dart';

part 'goods_list_cubit.freezed.dart';

/// Стадия загрузки списка товаров.
enum GoodsListStatus { initial, loading, loaded, error }

/// Состояние экрана «Остатки» (список товаров + фильтры). Одноклассовое со статусом —
/// список с фильтрами не требует union'а, а фильтры должны переживать перезагрузку.
@freezed
abstract class GoodsListState with _$GoodsListState {
  const factory GoodsListState({
    @Default(GoodsListStatus.initial) GoodsListStatus status,
    @Default(<Good>[]) List<Good> goods,
    @Default(0) int total,
    @Default(false) bool loadingMore, // идёт подгрузка следующей страницы
    @Default(<NomenclatureGroup>[]) List<NomenclatureGroup> groups,
    @Default(<Supplier>[]) List<Supplier> suppliers,
    String? query,
    String? groupId,
    String? supplierId,
    Failure? failure,
  }) = _GoodsListState;

  const GoodsListState._();

  /// Есть ли ещё непогруженные товары под текущие фильтры.
  bool get hasMore => goods.length < total;
}

/// Cubit экрана «Остатки»: держит справочники для фильтров (группы/поставщики) и
/// перезагружает список товаров при смене поиска/фильтра. Фабрика (свой на экран).
@injectable
class GoodsListCubit extends Cubit<GoodsListState> {
  GoodsListCubit(this._repo) : super(const GoodsListState());

  final CatalogRepository _repo;

  /// Отложенный поиск: не дёргаем API на каждый символ, а ждём паузы в наборе.
  ///
  /// Таймер живёт в cubit'е, а не в стейте экрана, намеренно. Раньше он был в
  /// `_GoodsListViewState`, и загасить его могли только те обработчики, что лежали рядом.
  /// Уход в карточку товара живёт в другом виджете (`GoodsResult`) и до таймера не дотягивался:
  /// экран списка при `push` не уничтожается, поэтому запрос уходил уже из-под карточки.
  /// При просадке связи ответ приходил ошибкой, `_load` ставил `status: error`, и кладовщик
  /// возвращался из карточки на экран ошибки, хотя поиск не трогал. Теперь загасить таймер
  /// может любой, у кого есть cubit.
  Timer? _searchDebounce;

  static const _debounceDelay = Duration(milliseconds: 350);

  /// Поиск по мере ввода: применяет запрос после паузы в наборе.
  void setQueryDebounced(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_debounceDelay, () => setQuery(value));
  }

  /// Отменить отложенный поиск. Вызывается при любом уходе с экрана: без этого
  /// запрос уходит уже из-под открытого поверх экрана, а его ошибка подменяет список.
  void cancelPendingSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
  }

  @override
  Future<void> close() {
    _searchDebounce?.cancel();
    return super.close();
  }

  /// Первичная загрузка: справочники фильтров (группы/поставщики) + первая страница товаров.
  Future<void> init() async {
    final groups = await _repo.listGroups();
    final suppliers = await _repo.listSuppliers();
    emit(
      state.copyWith(
        groups: groups.fold((_) => const [], (g) => g),
        suppliers: suppliers.fold((_) => const [], (s) => s),
      ),
    );
    await _load();
  }

  /// Поиск по имени/коду. Применяется сразу; отложенный вариант — `setQueryDebounced`.
  /// Гасим отложенный поиск: иначе «висящий» таймер применил бы более старый текст
  /// уже после этого вызова.
  Future<void> setQuery(String? query) async {
    cancelPendingSearch();
    emit(state.copyWith(query: (query ?? '').isEmpty ? null : query));
    await _load();
  }

  /// Резолв товара по отсканированному ШК (P-FS-16). `Right(null)` — ШК не привязан ни к одному
  /// товару, `Left` — спросить не удалось (нет связи или отказ сервера); экран показывает эти
  /// исходы по-разному, поэтому различает их он, а не cubit.
  ///
  /// Ошибку намеренно НЕ кладём в state (ADHOC-06). Раньше клали, и один скан подменял весь
  /// список экраном «не удалось загрузить» — при том что список загрузился нормально, а
  /// кладовщик его не трогал. Это тот же дефект, что закрывали в отложенном поиске (ADHOC-03):
  /// неудача точечного запроса рушит экран, к которому она отношения не имеет.
  Future<Either<Failure, Good?>> resolveBarcode(String code) =>
      _repo.resolveGoodByBarcode(code);

  /// Привязать отсканированный ШК к выбранному товару (ADHOC-06). Возвращает ошибку вызывающему
  /// и, как и [resolveBarcode], не кладёт её в state: список остался валидным.
  Future<Failure?> bindBarcode({
    required String goodId,
    required String barcode,
  }) async {
    final res = await _repo.bindBarcode(goodId: goodId, barcode: barcode);
    return res.fold((failure) => failure, (_) => null);
  }

  /// Фильтр по группе (null — снять).
  Future<void> setGroup(String? groupId) async {
    emit(state.copyWith(groupId: groupId));
    await _load();
  }

  /// Фильтр по поставщику (null — снять).
  Future<void> setSupplier(String? supplierId) async {
    emit(state.copyWith(supplierId: supplierId));
    await _load();
  }

  /// Сбросить фильтры (группа + поставщик) одним перезапросом. Строку поиска не трогаем.
  Future<void> resetFilters() async {
    emit(state.copyWith(groupId: null, supplierId: null));
    await _load();
  }

  /// Перезагрузка списка под текущие фильтры (с первой страницы — сбрасывает подгруженное).
  Future<void> _load() async {
    emit(
      state.copyWith(
        status: GoodsListStatus.loading,
        loadingMore: false,
        failure: null,
      ),
    );
    final result = await _repo.listGoods(
      query: state.query,
      groupId: state.groupId,
      supplierId: state.supplierId,
    );
    result.fold(
      (failure) =>
          emit(state.copyWith(status: GoodsListStatus.error, failure: failure)),
      (page) => emit(
        state.copyWith(
          status: GoodsListStatus.loaded,
          goods: page.items,
          total: page.total,
        ),
      ),
    );
  }

  /// Подгрузить следующую страницу (бесконечный скролл): дозапрашивает от `offset = goods.length`
  /// и дописывает в конец. Защита от повторного входа и от запроса за границей total. Ошибку
  /// подгрузки не роняем в error-экран (список уже показан) — просто снимаем флаг, скролл повторит.
  Future<void> loadMore() async {
    if (state.loadingMore ||
        state.status != GoodsListStatus.loaded ||
        !state.hasMore) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    final result = await _repo.listGoods(
      query: state.query,
      groupId: state.groupId,
      supplierId: state.supplierId,
      offset: state.goods.length,
    );
    result.fold(
      (_) => emit(state.copyWith(loadingMore: false)),
      (page) => emit(
        state.copyWith(
          loadingMore: false,
          goods: [...state.goods, ...page.items],
          total: page.total,
        ),
      ),
    );
  }
}
