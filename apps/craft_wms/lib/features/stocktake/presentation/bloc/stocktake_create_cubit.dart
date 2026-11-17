import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/stocktake_models.dart';
import '../../domain/stocktake_repository.dart';

part 'stocktake_create_cubit.freezed.dart';

/// Ячейка области - адрес для показа и id для сервера.
typedef ScopeCell = ({String id, String address});

/// Заведение пересчёта на ТСД (P10-04): старший смены (пока admin) выбирает простую область -
/// ячейки сканом, внутренний склад или весь склад. Группы, матрицы, поставщики и товары -
/// в портале (P10-05).
@freezed
abstract class StocktakeCreateState with _$StocktakeCreateState {
  const factory StocktakeCreateState({
    @Default(StocktakeScope.cells) String scopeKind,
    @Default(<ScopeCell>[]) List<ScopeCell> cells,
    String? internalWarehouseId,
    @Default(false) bool busy,
    Failure? failure,
    StocktakeCreated? created,
  }) = _StocktakeCreateState;

  const StocktakeCreateState._();

  /// Область задана: ячейки - хотя бы одна, склад - выбран, весь склад - всегда.
  bool get ready => switch (scopeKind) {
    StocktakeScope.cells => cells.isNotEmpty,
    StocktakeScope.internalWarehouse => internalWarehouseId != null,
    _ => true,
  };
}

/// Заведение пересчёта: область и «Завести».
@injectable
class StocktakeCreateCubit extends Cubit<StocktakeCreateState> {
  StocktakeCreateCubit(this._repo) : super(const StocktakeCreateState());

  final StocktakeRepository _repo;

  void selectScope(String kind) =>
      emit(state.copyWith(scopeKind: kind, failure: null));

  /// Добавить отсканированную ячейку; повтор - без изменений.
  void addCell(ScopeCell cell) {
    if (state.cells.any((c) => c.id == cell.id)) return;
    emit(state.copyWith(cells: [...state.cells, cell], failure: null));
  }

  void removeCell(ScopeCell cell) =>
      emit(state.copyWith(cells: [...state.cells]..remove(cell)));

  void selectWarehouse(String id) =>
      emit(state.copyWith(internalWarehouseId: id, failure: null));

  /// Завести пересчёт на складе [warehouseId] (склад ТСД).
  Future<void> create(String warehouseId) async {
    if (!state.ready || state.busy) return;
    emit(state.copyWith(busy: true, failure: null));
    final res = await _repo.create(
      warehouseId: warehouseId,
      scopeKind: state.scopeKind,
      objectIds: switch (state.scopeKind) {
        StocktakeScope.cells => [for (final c in state.cells) c.id],
        StocktakeScope.internalWarehouse => [state.internalWarehouseId!],
        _ => const [],
      },
    );
    if (isClosed) return;
    emit(
      state.copyWith(
        busy: false,
        created: res.isRight ? res.right : null,
        failure: res.isLeft ? res.left : null,
      ),
    );
  }
}
