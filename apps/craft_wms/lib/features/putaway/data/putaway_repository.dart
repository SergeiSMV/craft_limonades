import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import '../../tasks/data/tasks_cache.dart';
import '../../tasks/data/tasks_repository.dart';

/// Отправка сеанса размещения (P5-03).
///
/// Что: ставит сеанс в очередь одной операцией `putaway_submit` и сразу пробует отправить —
/// тем же путём, что приёмка. Не дошёл сейчас — уйдёт сам при появлении связи.
/// Зачем ещё и снимок заданий: после отправки список текущих должен показать задание таким,
/// каким его сделал сеанс. Со связью — свежий ответ сервера; без связи — снимок, в котором
/// размещённое уже отмечено, иначе кладовщик разместил бы его повторно.
@lazySingleton
class PutawayRepository {
  PutawayRepository(this._outbox, this._sync, this._tasks, this._cache);

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final TasksRepository _tasks;
  final TasksCache _cache;

  /// Отдать задание в пул — его незавершённый сеанс кладовщик отбросил.
  ///
  /// Только со связью: кто держит задание, знает сервер. Удалось — снимок текущих обновляется,
  /// чтобы задание сразу показалось «новым».
  Future<Either<Failure, void>> releaseTask(String taskId) async {
    final res = await _tasks.release(taskId);
    if (res.isRight) await _tasks.current();
    return res;
  }

  /// Поставить сеанс и попробовать отправить.
  ///
  /// `Right` — сервер провёл. `Left(RejectedFailure)` — отказ по существу: операция ждёт
  /// разбора. Любой другой `Left` — связи нет, сеанс в очереди; работа уже не потеряется.
  Future<Either<Failure, void>> submit({
    required Map<String, dynamic> payload,
    required String taskId,
    required Set<String> boxes,
    required Map<(String, String), double> loose,
  }) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.putawaySubmit,
      payload: payload,
    );
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) return const Right(null);
    final res = await _sync.sendOne(operation);
    if (res.isRight) {
      await _tasks.current();
    } else if (res.left is! RejectedFailure) {
      await _cache.applyPutaway(taskId: taskId, boxes: boxes, loose: loose);
    }
    return res;
  }
}
