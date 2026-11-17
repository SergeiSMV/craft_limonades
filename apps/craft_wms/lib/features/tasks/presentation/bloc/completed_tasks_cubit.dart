import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../data/tasks_models.dart';
import '../../data/tasks_repository.dart';

part 'completed_tasks_cubit.freezed.dart';

/// Стадия загрузки ленты.
enum CompletedStatus { initial, loading, loaded, error }

/// Состояние вкладки «Завершённые»: лента, фильтр и варианты фильтра по исполнителю.
@freezed
abstract class CompletedTasksState with _$CompletedTasksState {
  const factory CompletedTasksState({
    @Default(CompletedStatus.initial) CompletedStatus status,
    @Default(<CompletedTask>[]) List<CompletedTask> items,
    @Default(CompletedFilter()) CompletedFilter filter,
    @Default(true) bool hasMore,
    @Default(false) bool loadingMore,
    @Default(<TaskUser>[]) List<TaskUser> executors,
    Failure? failure,
  }) = _CompletedTasksState;
}

/// Cubit ленты «Завершённые» (P5-02-1): только онлайн, подгрузка курсором, фильтры.
@injectable
class CompletedTasksCubit extends Cubit<CompletedTasksState> {
  CompletedTasksCubit(this._repo) : super(const CompletedTasksState());

  final TasksRepository _repo;

  /// Размер страницы. Курсор - последняя показанная запись, а не смещение: завершения,
  /// случившиеся во время просмотра, не сдвигают уже загруженные страницы.
  static const pageSize = 30;

  /// Первая страница под текущий фильтр.
  Future<void> load() async {
    emit(
      state.copyWith(
        status: CompletedStatus.loading,
        items: const [],
        hasMore: true,
        loadingMore: false,
        failure: null,
      ),
    );
    final res = await _repo.completed(filter: state.filter, limit: pageSize);
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(status: CompletedStatus.error, failure: f)),
      (page) => emit(
        state.copyWith(
          status: CompletedStatus.loaded,
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
        state.status != CompletedStatus.loaded ||
        state.items.isEmpty) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    final res = await _repo.completed(
      filter: state.filter,
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

  /// Варианты фильтра по исполнителю. Не загрузились - фильтр по исполнителю просто пуст.
  Future<void> loadExecutors() async {
    final res = await _repo.executors();
    if (isClosed) return;
    res.fold((_) {}, (list) => emit(state.copyWith(executors: list)));
  }
}

/// Элемент ленты: разделитель дня или запись.
sealed class FeedEntry {
  const FeedEntry();
}

/// Разделитель - день, к которому относятся записи под ним.
class FeedDay extends FeedEntry {
  const FeedDay(this.day);
  final DateTime day;
}

/// Запись ленты.
class FeedTask extends FeedEntry {
  const FeedTask(this.task);
  final CompletedTask task;
}

/// Раскладывает ленту по дням, как чат: разделитель перед первой записью каждого дня.
/// День - по часам терминала: кладовщик думает о «сегодня» в своём времени.
List<FeedEntry> groupByDay(List<CompletedTask> items) {
  final out = <FeedEntry>[];
  DateTime? current;
  for (final it in items) {
    final local = it.completedAtTime.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (current != day) {
      out.add(FeedDay(day));
      current = day;
    }
    out.add(FeedTask(it));
  }
  return out;
}
