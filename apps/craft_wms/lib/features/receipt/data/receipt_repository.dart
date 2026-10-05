import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';

/// Отправка приёмки на сервер (P4-09).
///
/// Что: ставит приёмку в очередь операций одной операцией `receipt_submit` и сразу пробует
/// её отправить.
/// Зачем через очередь, а не прямыми ручками `POST /receipts…`: приёмку разгружают там, где
/// связь проседает, и операция в очереди переживает и обрыв, и перезапуск. Прямые ручки
/// (P4-03) остаются для отладки и для клиентов, которые работают только онлайн.
/// Как: тем же путём, что привязка ШК, — строка в очереди, затем `SyncEngine.sendOne`.
/// Не дошла сейчас — уйдёт сама при появлении связи.
@lazySingleton
class ReceiptRepository {
  ReceiptRepository(this._outbox, this._sync);

  final OutboxRepository _outbox;
  final SyncEngine _sync;

  /// Поставить приёмку и попробовать отправить.
  ///
  /// `Right` — сервер оприходовал. `Left(RejectedFailure)` — отказ по существу: операция лежит
  /// в очереди отклонённой и ждёт разбора. Любой другой `Left` — связи нет, операция ждёт
  /// отправки; работа кладовщика при этом уже не потеряется.
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.receiptSubmit,
      payload: payload,
    );
    final operation = await _outbox.byOperationId(operationId);
    // Строки нет, только если её успели убрать — тогда и отправлять нечего.
    if (operation == null) return const Right(null);
    return _sync.sendOne(operation);
  }
}
