import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/movement_history.dart';

/// Состояние карточки записи истории: грузится, загружена или ошибка.
sealed class MovementRecordState {
  const MovementRecordState();
}

class RecordLoading extends MovementRecordState {
  const RecordLoading();
}

class RecordLoaded extends MovementRecordState {
  const RecordLoaded(this.detail);
  final MoveRecordDetail detail;
}

class RecordFailed extends MovementRecordState {
  const RecordFailed(this.failure);
  final Failure failure;
}

/// Cubit карточки записи истории перемещений (ADHOC-28): строки по порядку проведения.
@injectable
class MovementRecordCubit extends Cubit<MovementRecordState> {
  MovementRecordCubit(this._repo) : super(const RecordLoading());

  final MovementHistoryRepository _repo;

  /// Загрузить запись (и повторить после ошибки).
  Future<void> load(String id) async {
    emit(const RecordLoading());
    final res = await _repo.record(id);
    if (isClosed) return;
    emit(res.fold(RecordFailed.new, RecordLoaded.new));
  }
}
