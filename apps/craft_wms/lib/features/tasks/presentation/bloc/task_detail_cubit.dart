import 'package:either_dart/either.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../data/tasks_models.dart';
import '../../data/tasks_repository.dart';

part 'task_detail_cubit.freezed.dart';

/// Состояние карточки задания.
///
/// Из «Текущих» задание приходит сразу (в том числе из снимка без связи); из ленты
/// «Завершённые» - только id, и задание дочитывается с сервера. Заходы и журнал - только
/// с сервера: [sessionsUnavailable] говорит, что показать историю сейчас нечем.
@freezed
abstract class TaskDetailState with _$TaskDetailState {
  const factory TaskDetailState({
    WarehouseTask? task,
    @Default(<TaskSession>[]) List<TaskSession> sessions,
    @Default(<TaskEvent>[]) List<TaskEvent> events,
    @Default(false) bool loading,
    @Default(false) bool sessionsUnavailable,
    @Default(false) bool busy,
    Failure? loadFailure,
    // Результат последнего действия: экран показывает его один раз и сбрасывает.
    TaskActionResult? lastAction,
  }) = _TaskDetailState;
}

/// Исход «Взять» / «Отказаться».
@freezed
sealed class TaskActionResult with _$TaskActionResult {
  const factory TaskActionResult.taken() = TaskTaken;
  const factory TaskActionResult.released() = TaskReleased;
  const factory TaskActionResult.failed(Failure failure) = TaskActionFailed;
}

/// Cubit карточки задания (P5-02-1): задание и заходы, взятие и отказ.
@injectable
class TaskDetailCubit extends Cubit<TaskDetailState> {
  TaskDetailCubit(
    this._repo,
    @factoryParam this._taskId,
    @factoryParam WarehouseTask? initial,
  ) : super(TaskDetailState(task: initial));

  final TasksRepository _repo;
  final String _taskId;

  /// Обновить задание и заходы с сервера. Без связи остаётся то, что передал список.
  Future<void> refresh() async {
    if (state.task == null) emit(state.copyWith(loading: true));
    final res = await _repo.detail(_taskId);
    if (isClosed) return;
    res.fold(
      (f) => emit(
        state.copyWith(
          loading: false,
          sessionsUnavailable: true,
          loadFailure: f,
        ),
      ),
      (r) => emit(
        state.copyWith(
          task: r.task,
          sessions: r.sessions,
          events: r.events,
          loading: false,
          sessionsUnavailable: false,
          loadFailure: null,
        ),
      ),
    );
  }

  /// Взять задание в работу - только со связью: кто держит задание, знает сервер.
  Future<void> take() => _act(_repo.take, const TaskActionResult.taken());

  /// Отказаться: задание возвращается в пул.
  Future<void> release() =>
      _act(_repo.release, const TaskActionResult.released());

  /// Показанный результат действия больше не нужен.
  void clearAction() => emit(state.copyWith(lastAction: null));

  Future<void> _act(
    Future<Either<Failure, void>> Function(String id) call,
    TaskActionResult ok,
  ) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true, lastAction: null));
    final res = await call(_taskId);
    if (isClosed) return;
    if (res.isLeft) {
      emit(
        state.copyWith(
          busy: false,
          lastAction: TaskActionResult.failed(res.left),
        ),
      );
      return;
    }
    emit(state.copyWith(busy: false, lastAction: ok));
    await refresh();
  }
}
