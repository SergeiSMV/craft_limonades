import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../domain/movement_history.dart';

part 'movement_history_cubit.freezed.dart';

/// Стадия загрузки ленты истории.
enum HistoryStatus { initial, loading, loaded, error }

/// Состояние вкладки «Завершённые» перемещения: лента, фильтр и варианты исполнителя.
///
/// Фильтр - тот же `CompletedFilter`, что у заданий (вид не используется): лист фильтра
/// общий, и кладовщик видит один и тот же фильтр в обоих разделах.
@freezed
abstract class MovementHistoryState with _$MovementHistoryState {
  const factory MovementHistoryState({
    @Default(HistoryStatus.initial) HistoryStatus status,
    @Default(<MoveRecord>[]) List<MoveRecord> items,
    @Default(CompletedFilter()) CompletedFilter filter,
    @Default(true) bool hasMore,
    @Default(false) bool loadingMore,
    @Default(<TaskUser>[]) List<TaskUser> executors,
    Failure? failure,
  }) = _MovementHistoryState;
}

/// Cubit ленты истории перемещений (ADHOC-28): всего склада, только онлайн, подгрузка
/// курсором, фильтр по периоду и исполнителю - отдельным запросом к серверу.
@injectable
class MovementHistoryCubit extends Cubit<MovementHistoryState> {
  MovementHistoryCubit(this._repo) : super(const MovementHistoryState());

  final MovementHistoryRepository _repo;

  /// Размер страницы. Курсор - последняя показанная запись, а не смещение: перемещения,
  /// проведённые во время просмотра, не сдвигают уже загруженные страницы.
  static const pageSize = 30;

  MoveHistoryQuery get _query => MoveHistoryQuery(
    from: state.filter.from,
    to: state.filter.to,
    executorId: state.filter.executor?.id,
  );

  /// Первая страница под текущий фильтр.
  Future<void> load() async {
    emit(
      state.copyWith(
        status: HistoryStatus.loading,
        items: const [],
        hasMore: true,
        loadingMore: false,
        failure: null,
      ),
    );
    final res = await _repo.page(query: _query, limit: pageSize);
    if (isClosed) return;
    res.fold(
      (f) => emit(state.copyWith(status: HistoryStatus.error, failure: f)),
      (page) => emit(
        state.copyWith(
          status: HistoryStatus.loaded,
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
        state.status != HistoryStatus.loaded ||
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

  /// Применить фильтр - лента перезагружается с первой страницы.
  Future<void> setFilter(CompletedFilter filter) async {
    emit(state.copyWith(filter: filter));
    await load();
  }

  /// Варианты фильтра по исполнителю. Не загрузились - фильтр по исполнителю просто пуст.
  Future<void> loadExecutors() async {
    final res = await _repo.executors();
    if (isClosed) return;
    res.fold(
      (_) {},
      (list) => emit(
        state.copyWith(
          executors: [
            for (final u in list) TaskUser(id: u.id, fullName: u.fullName),
          ],
        ),
      ),
    );
  }
}

/// Элемент ленты: разделитель дня или запись.
sealed class HistoryEntry {
  const HistoryEntry();
}

/// Разделитель - день, к которому относятся записи под ним.
class HistoryDay extends HistoryEntry {
  const HistoryDay(this.day);
  final DateTime day;
}

/// Запись ленты.
class HistoryRecord extends HistoryEntry {
  const HistoryRecord(this.record);
  final MoveRecord record;
}

/// Раскладывает ленту по дням, как чат: разделитель перед первой записью каждого дня.
/// День - по часам терминала, как у «Завершённых» заданий.
List<HistoryEntry> groupHistoryByDay(List<MoveRecord> items) {
  final out = <HistoryEntry>[];
  DateTime? current;
  for (final it in items) {
    final local = it.postedAtTime.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (current != day) {
      out.add(HistoryDay(day));
      current = day;
    }
    out.add(HistoryRecord(it));
  }
  return out;
}
