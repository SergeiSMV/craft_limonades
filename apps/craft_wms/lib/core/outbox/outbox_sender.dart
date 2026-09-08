import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../error/failure.dart';
import 'operations_api.dart';
import 'outbox_operation.dart';

/// Исполнитель операций очереди (P2-04, переведён на батч в P2-05).
///
/// Что: отправляет операции очереди на сервер и переводит ответ в доменный исход.
/// Зачем: движок синхронизации не должен знать ни одного маршрута API — иначе добавление
///        нового типа операции правило бы и очередь, и движок, и сеть сразу.
/// Как: единственный маршрут `POST /operations`; тип операции едет полем, а не адресом.
///
/// **Почему больше не «маршрут на тип операции».** До P2-05 привязка уходила в `POST /barcodes`,
/// отвязка — в `DELETE /barcodes/{code}`, и `operation_id` не ехал никуда: сервер не мог
/// отличить повтор от нового дела. Ключ идемпотентности некуда было положить, не изобретая
/// заголовок для каждой ручки. Общая ручка решает это один раз для всех типов операций.
@lazySingleton
class OutboxSender {
  OutboxSender(this._api);

  final OperationsApi _api;

  /// Отправить пачку операций и вернуть исход КАЖДОЙ по её `operation_id`.
  ///
  /// `Left` — запрос не состоялся целиком: вся пачка остаётся в очереди.
  /// `Right` — карта исходов. Операции в ней может не быть: сервер прекращает разбор на первой
  /// временной неудаче, чтобы не нарушить порядок. Отсутствие исхода означает «не применялась».
  Future<Either<Failure, Map<String, Either<Failure, void>>>> sendBatch(
    List<OutboxOperation> operations,
  ) async {
    final res = await _api.send(operations);
    return res.map(
      (replies) => {
        for (final reply in replies) reply.operationId: _outcomeToResult(reply),
      },
    );
  }

  /// Выполнить одну операцию.
  ///
  /// `Right` — сервер принял (в том числе если это был повтор уже применённой операции).
  /// `Left` — отказ; повторять его или нет, решает движок по [isRetryable].
  ///
  /// Одна операция отправляется тем же батчем из одного элемента, что и очередь целиком:
  /// два пути отправки уже расходились однажды (P2-06, отложенная привязка не доезжала
  /// до кэша), и заводить второй ради экономии одного элемента в массиве незачем.
  Future<Either<Failure, void>> send(OutboxOperation operation) async {
    final res = await sendBatch([operation]);
    return res.fold(
      Left.new,
      (outcomes) =>
          // Сервер не дошёл до операции — прервал разбор на временной неудаче.
          // Для очереди это «попробуем позже», а не отказ.
          outcomes[operation.operationId] ?? const Left(Failure.network()),
    );
  }

  /// Перевод исхода сервера в результат для движка.
  Either<Failure, void> _outcomeToResult(OperationReply reply) {
    return switch (reply.outcome) {
      // Повтор уже применённой операции — успех: дело сделано, держать её в очереди незачем.
      OperationOutcome.accepted ||
      OperationOutcome.duplicate => const Right(null),
      OperationOutcome.rejected => Left(
        Failure.rejected(reply.error ?? 'сервер отклонил операцию'),
      ),
    };
  }
}
