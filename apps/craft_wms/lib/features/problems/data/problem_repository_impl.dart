import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/warehouse/internal_warehouses.dart';
import '../domain/problem_repository.dart';

/// Отправка проблемы склада тем же путём, что движение (P6-07-2): в очередь и сразу попытка.
///
/// Без связи проблема уйдёт сама; до этого её накладывает чтение содержимого
/// (`PendingOverlay`) — короб уже «Брак» и на терминале.
@LazySingleton(as: ProblemRepository)
class ProblemRepositoryImpl implements ProblemRepository {
  ProblemRepositoryImpl(this._outbox, this._sync, this._warehouses);

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final InternalWarehouses _warehouses;

  @override
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.problemSubmit,
      payload: payload,
    );
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) return const Right(null);
    return _sync.sendOne(operation);
  }

  @override
  Future<List<InternalWarehouse>> markWarehouses() async => [
    for (final w in await _warehouses.all())
      if (!w.isDefault && w.isActive) w,
  ];
}
