import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/load_unit/load_unit_id_generator.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/outbox/sent_sessions.dart';
import '../../../core/sync/sync_engine.dart';
import '../../tasks/data/tasks_cache.dart';
import 'putaway_draft_store.dart';
import '../../tasks/data/tasks_repository.dart';

/// Отправка сеанса размещения (P5-03).
///
/// Что: ставит сеанс в очередь одной операцией `putaway_submit` и сразу пробует отправить -
/// тем же путём, что приёмка. Не дошёл сейчас - уйдёт сам при появлении связи.
/// Зачем ещё и снимок заданий: после отправки список текущих должен показать задание таким,
/// каким его сделал сеанс. Со связью - свежий ответ сервера; без связи - снимок, в котором
/// размещённое уже отмечено, иначе кладовщик разместил бы его повторно.
@lazySingleton
class PutawayRepository {
  PutawayRepository(
    this._outbox,
    this._sync,
    this._tasks,
    this._cache,
    this._drafts,
    this._sent,
    this._ids,
  );

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final TasksRepository _tasks;
  final TasksCache _cache;
  final PutawayDraftStore _drafts;
  final SentSessionStore _sent;
  final LoadUnitIdGenerator _ids;

  /// Отдать задание в пул - его незавершённый сеанс кладовщик отбросил.
  ///
  /// Только со связью: кто держит задание, знает сервер. Удалось - снимок текущих обновляется,
  /// чтобы задание сразу показалось «новым».
  Future<Either<Failure, void>> releaseTask(String taskId) async {
    final res = await _tasks.release(taskId);
    if (res.isRight) await _tasks.current();
    return res;
  }

  /// Поставить сеанс и попробовать отправить.
  ///
  /// [session] - слепок сеанса (как черновик): по нему отклонённый документ возвращается
  /// в черновик (ADHOC-41).
  ///
  /// `result`: `Right` - сервер провёл. `Left(RejectedFailure)` - отказ по существу: операция
  /// [operationId] ждёт разбора. Любой другой `Left` - связи нет, сеанс в очереди; работа уже
  /// не потеряется.
  Future<({String operationId, Either<Failure, void> result})> submit({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> session,
    required String taskId,
    required Set<String> boxes,
    required Map<(String, String), double> loose,
  }) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.putawaySubmit,
      payload: payload,
    );
    // Слепок - до отправки: отказ может прийти и сразу, и позже, из движка синхронизации.
    await _sent.save(operationId, session);
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) {
      return (
        operationId: operationId,
        result: const Right<Failure, void>(null),
      );
    }
    final res = await _sync.sendOne(operation);
    if (res.isRight) {
      await _tasks.current();
    } else if (res.left is! RejectedFailure) {
      await _cache.applyPutaway(taskId: taskId, boxes: boxes, loose: loose);
    }
    return (operationId: operationId, result: res);
  }

  /// Вернуть отклонённый сеанс [operationId] в черновик для правки (ADHOC-41, долг 26).
  ///
  /// Сеанс получает новый идентификатор документа и причину отказа, операция уходит из
  /// очереди; откроется он в своём задании. Второе значение - номер задания, чтобы сказать
  /// кладовщику, куда идти. Черновик уже есть - [ReopenOutcome.draftBusy]: он один на все
  /// задания, и новый затёр бы чужую работу.
  Future<(ReopenOutcome, int)> reopenRejected(String operationId) async {
    if (await _drafts.load() != null) return (ReopenOutcome.draftBusy, 0);
    final session = await _sent.load(operationId);
    if (session == null) return (ReopenOutcome.lost, 0);
    final operation = await _outbox.byOperationId(operationId);
    await _drafts.save({
      ...session,
      'putaway_id': _ids.newId(),
      'fix_reason': operation?.lastError,
    });
    await _outbox.discard(operationId);
    return (ReopenOutcome.reopened, session['task_number'] as int? ?? 0);
  }
}
