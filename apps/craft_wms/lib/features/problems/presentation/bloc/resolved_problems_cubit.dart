import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../domain/problem_records.dart';

part 'resolved_problems_cubit.freezed.dart';

/// Стадия загрузки ленты решённых проблем.
enum ResolvedStatus { initial, loading, loaded, error }

/// Состояние вкладки «Завершённые» в «Проблемах склада» (ADHOC-34).
///
/// Фильтр - тот же `CompletedFilter`, что у заданий и перемещений (используется только
/// период): лист фильтра общий, кладовщик видит один и тот же фильтр во всех лентах.
@freezed
abstract class ResolvedProblemsState with _$ResolvedProblemsState {
  const factory ResolvedProblemsState({
    @Default(ResolvedStatus.initial) ResolvedStatus status,
    @Default(<ProblemRecord>[]) List<ProblemRecord> items,
    @Default(CompletedFilter()) CompletedFilter filter,
    @Default(true) bool hasMore,
    @Default(false) bool loadingMore,
    Failure? failure,
  }) = _ResolvedProblemsState;
}

/// Cubit ленты решённых проблем (ADHOC-34): всего склада, только онлайн, подгрузка курсором,
/// фильтр по периоду - отдельным запросом к серверу.
@injectable
class ResolvedProblemsCubit extends Cubit<ResolvedProblemsState> {
  ResolvedProblemsCubit(this._repo) : super(const ResolvedProblemsState());

  final ProblemRecordsRepository _repo;

  /// Размер страницы. Курсор - последняя показанная запись, а не смещение: решения, принятые
  /// во время просмотра, не сдвигают уже загруженные страницы.
  static const pageSize = 30;

  ResolvedProblemsQuery get _query =>
      ResolvedProblemsQuery(from: state.filter.from, to: state.filter.to);

  /// Первая страница под текущий фильтр.
  Future<void> load() async {
    emit(
      state.copyWith(
        status: ResolvedStatus.loading,
        items: const [],
        hasMore: true,
        loadingMore: false,
        failure: null,
      ),
    );
    final res = await _repo.resolved(query: _query, limit: pageSize);
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(status: ResolvedStatus.error, failure: f)),
      (page) => emit(
        state.copyWith(
          status: ResolvedStatus.loaded,
          items: page,
          hasMore: page.length == pageSize,
        ),
      ),
    );
  }

  /// Следующая страница. Неудача подгрузки не роняет ленту в ошибку - уже показанное
  /// остаётся, а следующий скролл повторит запрос.
  Future<void> loadMore() async {
    if (state.loadingMore ||
        !state.hasMore ||
        state.status != ResolvedStatus.loaded ||
        state.items.isEmpty) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    final res = await _repo.resolved(
      query: _query,
      after: state.items.last,
      limit: pageSize,
    );
    if (isClosed) return;
    res.fold(
      (_) => emit(state.copyWith(loadingMore: false)),
      (page) => emit(
        state.copyWith(
          loadingMore: false,
          items: [...state.items, ...page],
          hasMore: page.length == pageSize,
        ),
      ),
    );
  }

  /// Применить фильтр - лента перезагружается с первой страницы.
  Future<void> setFilter(CompletedFilter filter) async {
    emit(state.copyWith(filter: filter));
    await load();
  }
}
