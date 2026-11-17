import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import 'tasks_api.dart';
import 'tasks_cache.dart';
import 'tasks_models.dart';

/// Текущие задания вместе с тем, откуда они взяты.
typedef CurrentTasks = ({
  List<WarehouseTask> tasks,
  bool fromCache,
  DateTime? syncedAt,
});

/// Задания склада для экранов (P5-02-1): сеть, а без связи - снимок текущих.
///
/// Взятие, отказ и лента «Завершённые» - только со связью: кто держит задание, знает сервер,
/// а ленту по решению 2026-10-07 офлайн не держим.
@lazySingleton
class TasksRepository {
  TasksRepository(this._api, this._cache);

  final TasksApi _api;
  final TasksCache _cache;

  /// Текущие задания. Удачный ответ сервера обновляет снимок; без связи отдаётся снимок.
  Future<Either<Failure, CurrentTasks>> current() async {
    final res = await _api.current();
    if (res.isRight) {
      final now = DateTime.now();
      await _cache.replace(res.right, now);
      return Right((tasks: res.right, fromCache: false, syncedAt: now));
    }
    if (res.left is! NetworkFailure) return Left(res.left);
    final snapshot = await _cache.read();
    // Снимка нет совсем - показать нечего, и честнее сказать «нет связи», чем «заданий нет».
    if (snapshot == null) return Left(res.left);
    final (tasks, syncedAt) = snapshot;
    return Right((tasks: tasks, fromCache: true, syncedAt: syncedAt));
  }

  /// Число текущих заданий по снимку на терминале - для плитки главного меню; [allow] -
  /// только виды по правам должности (ADHOC-51).
  Stream<int> watchCurrentCount({bool Function(String kind)? allow}) =>
      _cache.watchCount(allow: allow);

  /// Карточка задания с заходами и журналом - по сети.
  Future<Either<Failure, TaskDetailData>> detail(String id) => _api.detail(id);

  /// Взять задание в работу.
  Future<Either<Failure, void>> take(String id) => _api.take(id);

  /// Отказаться от задания.
  Future<Either<Failure, void>> release(String id) => _api.release(id);

  /// Страница ленты «Завершённые».
  Future<Either<Failure, List<CompletedTask>>> completed({
    required CompletedFilter filter,
    CompletedTask? after,
    int limit = 30,
  }) => _api.completed(filter: filter, after: after, limit: limit);

  /// Варианты фильтра по исполнителю.
  Future<Either<Failure, List<TaskUser>>> executors() => _api.executors();
}
