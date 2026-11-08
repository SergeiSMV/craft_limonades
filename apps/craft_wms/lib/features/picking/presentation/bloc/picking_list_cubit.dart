import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_repository.dart';
import '../../domain/picking_view.dart';

part 'picking_list_cubit.freezed.dart';

enum PickingListStatus { loading, loaded, error }

/// Список «СБОРКА» (P9-06): заказы с сервера; без связи - свои заказы на терминале.
@freezed
abstract class PickingListState with _$PickingListState {
  const factory PickingListState({
    @Default(PickingListStatus.loading) PickingListStatus status,
    @Default(<PickingListItem>[]) List<PickingListItem> orders,

    /// Свои заказы со слепком на терминале - видны, когда связи нет.
    @Default(<PickingOrderView>[]) List<PickingOrderView> onTerminal,
    Failure? failure,
  }) = _PickingListState;

  const PickingListState._();

  /// В работе у этого кладовщика.
  List<PickingListItem> get mine => orders.where((o) => o.mine).toList();

  /// Свободные: никто не держит, зависший - тоже свободный.
  List<PickingListItem> get free =>
      orders.where((o) => !o.mine && !o.busy).toList();

  /// У других кладовщиков.
  List<PickingListItem> get busy =>
      orders.where((o) => !o.mine && o.busy).toList();
}

@injectable
class PickingListCubit extends Cubit<PickingListState> {
  PickingListCubit(this._repo) : super(const PickingListState());

  final PickingRepository _repo;

  Future<void> load() async {
    final res = await _repo.orders();
    if (isClosed) return;
    if (res.isRight) {
      emit(
        state.copyWith(
          status: PickingListStatus.loaded,
          orders: res.right,
          failure: null,
        ),
      );
      return;
    }
    final local = await _repo.onTerminal();
    if (isClosed) return;
    emit(
      state.copyWith(
        status: PickingListStatus.error,
        failure: res.left,
        onTerminal: local,
      ),
    );
  }
}
