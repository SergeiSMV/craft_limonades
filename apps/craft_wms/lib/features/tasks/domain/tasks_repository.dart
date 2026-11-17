import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'tasks_models.dart';

/// Текущие задания вместе с тем, откуда они взяты.
typedef CurrentTasks = ({
  List<WarehouseTask> tasks,
  bool fromCache,
  DateTime? syncedAt,
});

/// Задания склада для экранов и чужих фич (P5-02-1).
///
/// Что: текущие задания (сеть, а без связи - снимок), карточка, взятие и отказ, лента
/// «Завершённые» и её фильтр по исполнителю.
/// Зачем абстракция: экраны и фичи, которые обновляют снимок после своих операций
/// (размещение, пересчёт, возврат поставщику), не знают про API и кэш заданий
/// (`dev.md §2`, ADHOC-71).
/// Как реализовано - `TasksRepositoryImpl` в `data`.
abstract interface class TasksRepository {
  /// Текущие задания. Удачный ответ сервера обновляет снимок; без связи отдаётся снимок.
  Future<Either<Failure, CurrentTasks>> current();

  /// Число текущих заданий по снимку на терминале - для плитки главного меню; [allow] -
  /// только виды по правам должности (ADHOC-51).
  Stream<int> watchCurrentCount({bool Function(String kind)? allow});

  /// Карточка задания с заходами и журналом - по сети.
  Future<Either<Failure, TaskDetailData>> detail(String id);

  /// Взять задание в работу.
  Future<Either<Failure, void>> take(String id);

  /// Отказаться от задания.
  Future<Either<Failure, void>> release(String id);

  /// Страница ленты «Завершённые».
  Future<Either<Failure, List<CompletedTask>>> completed({
    required CompletedFilter filter,
    CompletedTask? after,
    int limit = 30,
  });

  /// Варианты фильтра по исполнителю.
  Future<Either<Failure, List<TaskUser>>> executors();
}
