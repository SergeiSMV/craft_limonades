import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/picking_models.dart';
import '../../domain/picking_repository.dart';

part 'picking_shipped_cubit.freezed.dart';

enum PickingShippedStatus { loading, loaded, error }

/// «Завершённые» в «СБОРКЕ»: отгруженные заказы за дату накладной, как календарь портала.
@freezed
abstract class PickingShippedState with _$PickingShippedState {
  const factory PickingShippedState({
    required DateTime date,
    @Default(PickingShippedStatus.loading) PickingShippedStatus status,
    @Default(<PickingListItem>[]) List<PickingListItem> orders,
    Failure? failure,
  }) = _PickingShippedState;
}

/// Отгруженные заказы за выбранную дату; по умолчанию - сегодня. Только со связью.
@injectable
class PickingShippedCubit extends Cubit<PickingShippedState> {
  PickingShippedCubit(this._repo)
    : super(PickingShippedState(date: _day(DateTime.now())));

  final PickingRepository _repo;

  /// Выбрать дату накладной и загрузить её заказы.
  Future<void> setDate(DateTime date) async {
    emit(state.copyWith(date: _day(date)));
    await load();
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> load() async {
    emit(state.copyWith(status: PickingShippedStatus.loading));
    final res = await _repo.shipped(state.date);
    if (isClosed) return;
    res.fold(
      (f) =>
          emit(state.copyWith(status: PickingShippedStatus.error, failure: f)),
      (list) => emit(
        state.copyWith(
          status: PickingShippedStatus.loaded,
          orders: list,
          failure: null,
        ),
      ),
    );
  }
}
