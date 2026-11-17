import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/contents_entities.dart';
import '../../domain/contents_repository.dart';

/// Состояние блока истории короба (P5-05-1).
sealed class HistoryState {
  const HistoryState();
}

final class HistoryLoading extends HistoryState {
  const HistoryLoading();
}

final class HistoryLoaded extends HistoryState {
  const HistoryLoaded(this.history);

  final LoadUnitHistory history;
}

final class HistoryFailed extends HistoryState {
  const HistoryFailed(this.failure);

  final Failure failure;
}

/// История короба - только со связью: журнал размещений растёт без конца, и на терминал
/// его не тянем (P5-05-1).
@injectable
class LoadUnitHistoryCubit extends Cubit<HistoryState> {
  LoadUnitHistoryCubit(this._repo) : super(const HistoryLoading());

  final ContentsRepository _repo;

  /// Загрузить историю короба.
  Future<void> load(String id) async {
    emit(const HistoryLoading());
    final res = await _repo.history(id);
    if (isClosed) return;
    emit(res.fold(HistoryFailed.new, HistoryLoaded.new));
  }
}
