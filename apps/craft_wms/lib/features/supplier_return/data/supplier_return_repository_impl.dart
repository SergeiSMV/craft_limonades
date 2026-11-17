import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import '../../tasks/data/tasks_cache.dart';
import '../../tasks/data/tasks_repository.dart';
import '../domain/supplier_return_repository.dart';

/// Отправка сеанса отгрузки возврата (ADHOC-31) - тем же путём, что размещение: одна операция
/// `return_submit` в очередь и сразу попытка отправить. Со связью снимок заданий берётся
/// свежим с сервера; без связи отгруженное отмечается в снимке, иначе кладовщик увидел бы
/// задание невыполненным и отгрузил бы его повторно.
@LazySingleton(as: SupplierReturnRepository)
class SupplierReturnRepositoryImpl implements SupplierReturnRepository {
  SupplierReturnRepositoryImpl(
    this._outbox,
    this._sync,
    this._tasks,
    this._cache,
  );

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final TasksRepository _tasks;
  final TasksCache _cache;

  @override
  Future<Either<Failure, void>> submit({
    required Map<String, dynamic> payload,
    required String taskId,
    required Set<String> problemIds,
  }) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.returnSubmit,
      payload: payload,
    );
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) return const Right(null);
    final res = await _sync.sendOne(operation);
    if (res.isRight) {
      await _tasks.current();
    } else if (res.left is! RejectedFailure) {
      await _cache.applyReturn(taskId: taskId, problemIds: problemIds);
    }
    return res;
  }
}
