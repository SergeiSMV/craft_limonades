import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../domain/problem_records.dart';

/// Стадия вкладки «Текущие».
enum CurrentStatus { initial, loading, loaded }

/// Состояние вкладки «Текущие» (ADHOC-35): свои неотправленные и открытые склада.
class CurrentProblemsState {
  const CurrentProblemsState({
    this.status = CurrentStatus.initial,
    this.data = const CurrentProblems(),
  });

  final CurrentStatus status;
  final CurrentProblems data;

  /// Всё, что показать списком: свои неотправленные сверху, затем открытые склада.
  List<ProblemRecord> get items => [...data.pending, ...data.open];
}

/// Cubit вкладки «Текущие» в «Проблемах склада» (ADHOC-35): открытые проблемы всего склада
/// с сервера и свои неотправленные из очереди. Без связи — только свои, с подсказкой.
@injectable
class CurrentProblemsCubit extends Cubit<CurrentProblemsState> {
  CurrentProblemsCubit(this._repo) : super(const CurrentProblemsState());

  final ProblemRecordsRepository _repo;

  /// Загрузить список заново: при открытии раздела, «потянуть вниз», после фиксации.
  Future<void> load() async {
    emit(CurrentProblemsState(status: CurrentStatus.loading, data: state.data));
    final data = await _repo.current();
    if (isClosed) return;
    emit(CurrentProblemsState(status: CurrentStatus.loaded, data: data));
  }
}
