import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import '../domain/picking_return.dart';
import '../domain/picking_return_repository.dart';
import 'picking_api.dart';

/// Возврат на места (P9-07-1): что вернуть - запросом к серверу, сам возврат - операцией
/// очереди тем же путём, что пик: в очередь и сразу попытка отправить.
@LazySingleton(as: PickingReturnRepository)
class PickingReturnRepositoryImpl implements PickingReturnRepository {
  PickingReturnRepositoryImpl(this._api, this._outbox, this._sync, this._uuid);

  final PickingApi _api;
  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final Uuid _uuid;

  @override
  Future<Either<Failure, PickingReturnView>> view(String orderId) =>
      _api.returnView(orderId);

  @override
  Future<Either<Failure, void>> putBack(
    PickingReturnPick pick, {
    required double qty,
    required String cellId,
    List<String> marks = const [],
  }) => _enqueue(OutboxKind.pickingReturn, {
    'return_id': _uuid.v4(),
    'pick_id': pick.pickId,
    'cell_id': cellId,
    'qty': qty.toString(),
    'marks': marks,
  });

  @override
  Future<Either<Failure, void>> unpick(PickingReturnPick pick) =>
      _enqueue(OutboxKind.pickingUnpick, {'pick_id': pick.pickId});

  /// Поставить операцию в очередь и сразу попробовать отправить.
  Future<Either<Failure, void>> _enqueue(
    OutboxKind kind,
    Map<String, dynamic> payload,
  ) async {
    final operationId = await _outbox.enqueue(kind: kind, payload: payload);
    final op = await _outbox.byOperationId(operationId);
    if (op == null) return const Right(null);
    return _sync.sendOne(op);
  }
}
