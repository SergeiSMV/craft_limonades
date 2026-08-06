import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';

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
    @Default(<NomenclatureGroup>[]) List<NomenclatureGroup> groups,
    @Default(<Supplier>[]) List<Supplier> suppliers,
    String? query,
    String? groupId,
    String? supplierId,
    Failure? failure,
  }) = _GoodsListState;
}

/// Cubit экрана «Остатки»: держит справочники для фильтров (группы/поставщики) и
/// перезагружает список товаров при смене поиска/фильтра. Фабрика (свой на экран).
@injectable
class GoodsListCubit extends Cubit<GoodsListState> {
  GoodsListCubit(this._repo) : super(const GoodsListState());

  final CatalogRepository _repo;

  /// Первичная загрузка: справочники фильтров (группы/поставщики) + первая страница товаров.
  Future<void> init() async {
    final groups = await _repo.listGroups();
    final suppliers = await _repo.listSuppliers();
    emit(state.copyWith(
      groups: groups.fold((_) => const [], (g) => g),
      suppliers: suppliers.fold((_) => const [], (s) => s),
    ));
    await _load();
  }

  /// Поиск по имени/коду (вызывается с дебаунсом из экрана).
  Future<void> setQuery(String? query) async {
    emit(state.copyWith(query: (query ?? '').isEmpty ? null : query));
    await _load();
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

  /// Перезагрузка списка под текущие фильтры.
  Future<void> _load() async {
    emit(state.copyWith(status: GoodsListStatus.loading, failure: null));
    final result = await _repo.listGoods(
      query: state.query,
      groupId: state.groupId,
      supplierId: state.supplierId,
    );
    result.fold(
      (failure) => emit(state.copyWith(status: GoodsListStatus.error, failure: failure)),
      (page) => emit(state.copyWith(
        status: GoodsListStatus.loaded,
        goods: page.items,
        total: page.total,
      )),
    );
  }
}
