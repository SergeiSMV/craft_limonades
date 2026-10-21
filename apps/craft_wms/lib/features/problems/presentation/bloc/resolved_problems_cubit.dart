import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../domain/resolved_problems.dart';

part 'resolved_problems_cubit.freezed.dart';

/// Стадия загрузки ленты решённых проблем.
enum ResolvedStatus { initial, loading, loaded, error }

/// Состояние вкладки «Завершённые» в «Проблемах склада» (ADHOC-34).
///
/// Фильтр — тот же `CompletedFilter`, что у заданий и перемещений (используется только
/// период): лист фильтра общий, кладовщик видит один и тот же фильтр во всех лентах.
@freezed
abstract class ResolvedProblemsState with _$ResolvedProblemsState {
  const factory ResolvedProblemsState({
    @Default(ResolvedStatus.initial) ResolvedStatus status,
    @Default(<ResolvedProblem>[]) List<ResolvedProblem> items,
    @Default(CompletedFilter()) CompletedFilter filter,
    @Default(true) bool hasMore,
    @Default(false) bool loadingMore,
    Failure? failure,
  }) = _ResolvedProblemsState;
}

/// Cubit ленты решённых проблем (ADHOC-34): всего склада, только онлайн, подгрузка курсором,
/// фильтр по периоду — отдельным запросом к серверу.
@injectable
class ResolvedProblemsCubit extends Cubit<ResolvedProblemsState> {
  ResolvedProblemsCubit(this._repo) : super(const ResolvedProblemsState());

  final ResolvedProblemsRepository _repo;

  /// Размер страницы. Курсор — последняя показанная запись, а не смещение: решения, принятые
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
    final res = await _repo.page(query: _query, limit: pageSize);
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

  /// Следующая страница. Неудача подгрузки не роняет ленту в ошибку — уже показанное
  /// остаётся, а следующий скролл повторит запрос.
  Future<void> loadMore() async {
    if (state.loadingMore ||
        !state.hasMore ||
        state.status != ResolvedStatus.loaded ||
        state.items.isEmpty) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    final res = await _repo.page(
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

  /// Применить фильтр — лента перезагружается с первой страницы.
  Future<void> setFilter(CompletedFilter filter) async {
    emit(state.copyWith(filter: filter));
    await load();
  }
}

/// Элемент ленты: разделитель дня или запись.
sealed class ResolvedEntry {
  const ResolvedEntry();
}

/// Разделитель — день, к которому относятся записи под ним.
class ResolvedDay extends ResolvedEntry {
  const ResolvedDay(this.day);
  final DateTime day;
}

/// Запись ленты.
class ResolvedRecord extends ResolvedEntry {
  const ResolvedRecord(this.problem);
  final ResolvedProblem problem;
}

/// Раскладывает ленту по дням решения, как чат: разделитель перед первой записью каждого дня.
/// День — по часам терминала, как у «Завершённых» заданий.
List<ResolvedEntry> groupResolvedByDay(List<ResolvedProblem> items) {
  final out = <ResolvedEntry>[];
  DateTime? current;
  for (final it in items) {
    final local = it.resolvedAtTime.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (current != day) {
      out.add(ResolvedDay(day));
      current = day;
    }
    out.add(ResolvedRecord(it));
  }
  return out;
}
