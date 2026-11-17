import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/tasks_models.dart';
import '../../domain/tasks_repository.dart';

part 'current_tasks_cubit.freezed.dart';

/// Стадия загрузки текущих заданий.
enum CurrentTasksStatus { initial, loading, loaded, error }

/// Состояние вкладки «Текущие».
///
/// [fromCache] - список взят из снимка на терминале, потому что связи нет; [syncedAt] -
/// когда снимок получен. Кладовщик должен видеть, что смотрит на вчерашний список.
///
/// [kind] - фильтр по виду задания. Фильтруется на терминале, а не запросом: список текущих
/// невелик и работает без связи, а фильтр обязан работать и над снимком.
@freezed
abstract class CurrentTasksState with _$CurrentTasksState {
  const factory CurrentTasksState({
    @Default(CurrentTasksStatus.initial) CurrentTasksStatus status,
    @Default(<WarehouseTask>[]) List<WarehouseTask> tasks,
    @Default(false) bool fromCache,
    DateTime? syncedAt,
    String? kind,
    Failure? failure,
  }) = _CurrentTasksState;

  const CurrentTasksState._();

  /// Задания под фильтром - то, что показывает вкладка.
  List<WarehouseTask> get visible =>
      kind == null ? tasks : tasks.where((t) => t.kind == kind).toList();
}

/// Cubit вкладки «Текущие» (P5-02-1): пул и свои взятые задания, офлайн - из снимка.
@injectable
class CurrentTasksCubit extends Cubit<CurrentTasksState> {
  CurrentTasksCubit(this._repo) : super(const CurrentTasksState());

  final TasksRepository _repo;

  /// Загрузить текущие. Повторная загрузка при уже показанном списке не прячет его за
  /// индикатором: список остаётся, пока не придёт новый (урок долга 11).
  Future<void> load() async {
    if (state.status != CurrentTasksStatus.loaded) {
      emit(state.copyWith(status: CurrentTasksStatus.loading, failure: null));
    }
    final res = await _repo.current();
    if (isClosed) return;
    res.fold(
      (failure) {
        // Список уже был - ошибка его не заменяет, а лишь помечает.
        if (state.status == CurrentTasksStatus.loaded) {
          emit(state.copyWith(failure: failure));
          return;
        }
        emit(
          state.copyWith(status: CurrentTasksStatus.error, failure: failure),
        );
      },
      (r) => emit(
        state.copyWith(
          status: CurrentTasksStatus.loaded,
          tasks: r.tasks,
          fromCache: r.fromCache,
          syncedAt: r.syncedAt,
          failure: null,
        ),
      ),
    );
  }

  /// Фильтр по виду задания (null - все виды).
  void setKind(String? kind) => emit(state.copyWith(kind: kind));
}
