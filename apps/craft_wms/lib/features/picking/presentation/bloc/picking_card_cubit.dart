import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/picking_card.dart';
import '../../domain/picking_repository.dart';

part 'picking_card_cubit.freezed.dart';

enum PickingCardStatus { loading, loaded, error }

/// Карточка заказа сборки (ADHOC-62): загрузка, ошибка с повтором.
@freezed
abstract class PickingCardState with _$PickingCardState {
  const factory PickingCardState({
    @Default(PickingCardStatus.loading) PickingCardStatus status,
    PickingCard? card,
    Failure? failure,
  }) = _PickingCardState;
}

/// Карточка заказа [_orderId] - только со связью, только чтение.
@injectable
class PickingCardCubit extends Cubit<PickingCardState> {
  PickingCardCubit(this._repo, @factoryParam this._orderId)
    : super(const PickingCardState());

  final PickingRepository _repo;
  final String _orderId;

  Future<void> load() async {
    emit(state.copyWith(status: PickingCardStatus.loading));
    final res = await _repo.card(_orderId);
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(status: PickingCardStatus.error, failure: f)),
      (card) => emit(
        state.copyWith(
          status: PickingCardStatus.loaded,
          card: card,
          failure: null,
        ),
      ),
    );
  }
}
