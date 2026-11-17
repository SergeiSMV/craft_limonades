import 'dart:async';

import 'package:injectable/injectable.dart';

import '../domain/tasks_snapshot_sync.dart';
import 'tasks_repository.dart';

/// Обновление снимка текущих заданий по подтверждению операций очереди (ADHOC-24).
///
/// Как: через ту же загрузку, что у раздела «Задания» ([TasksRepository.current]) - удачный
/// ответ заменяет снимок, и плитка главного экрана, подписанная на число в снимке, обновляется
/// сама. Без связи загрузка не удастся, и снимок останется прежним.
@LazySingleton(as: TasksSnapshotSync)
class TasksSnapshotSyncImpl implements TasksSnapshotSync {
  TasksSnapshotSyncImpl(this._repo);

  final TasksRepository _repo;

  /// Пауза перед загрузкой: очередь подтверждает операции пачкой, а задания достаточно
  /// подтянуть один раз после неё.
  static const _debounce = Duration(seconds: 2);

  Timer? _timer;

  @override
  void requestRefresh() {
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(_repo.current()));
  }
}
