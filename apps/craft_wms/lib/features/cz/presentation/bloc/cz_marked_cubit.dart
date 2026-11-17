import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/cz_good_repository.dart';

part 'cz_marked_cubit.freezed.dart';

/// Признак «маркируемый» в карточке товара (CZ-05).
@freezed
abstract class CzMarkedState with _$CzMarkedState {
  const factory CzMarkedState({
    @Default('') String goodId,
    @Default(false) bool marked,

    /// Правка ушла на сервер и ждёт ответа: повторный выбор не принимается.
    @Default(false) bool saving,

    /// Последняя правка не сохранилась; признак остался прежним.
    Failure? failure,
  }) = _CzMarkedState;
}

/// Cubit признака «маркируемый»: показывает его и сохраняет правку admin.
@injectable
class CzMarkedCubit extends Cubit<CzMarkedState> {
  CzMarkedCubit(this._repo) : super(const CzMarkedState());

  final CzGoodRepository _repo;

  /// Товар карточки и его признак из справочника.
  void start({required String goodId, required bool marked}) =>
      emit(CzMarkedState(goodId: goodId, marked: marked));

  /// Сохранить новый признак. Тот же или правка ещё в пути - ничего не делаем; отказ -
  /// признак прежний, причина в состоянии.
  Future<void> set(bool marked) async {
    if (state.saving || state.marked == marked) return;
    emit(state.copyWith(saving: true, failure: null));
    final res = await _repo.setCzMarked(goodId: state.goodId, marked: marked);
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(saving: false, failure: f)),
      (_) => emit(state.copyWith(saving: false, marked: marked)),
    );
  }
}
