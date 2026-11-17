import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:either_dart/either.dart';
import 'package:mocktail/mocktail.dart';

/// Мок транспорта батча операций (P2-05).
class MockOperationsApi extends Mock implements OperationsApi {}

/// Зарегистрировать значение-заглушку для `any()` по списку операций.
/// Mocktail требует его для любого не-nullable типа аргумента.
void registerOutboxFallbacks() {
  registerFallbackValue(<OutboxOperation>[]);
}

/// Сервер ответил на батч: каждой операции - один и тот же исход.
///
/// Ответы строятся ПО ОТПРАВЛЕННЫМ операциям, а не выдаются заранее заготовленным списком:
/// движок сопоставляет ответ со строкой очереди по `operation_id`, и заглушка с чужим
/// идентификатором проверяла бы не то.
void stubBatchOutcome(
  MockOperationsApi api,
  OperationOutcome outcome, {
  String? error,
}) {
  when(() => api.send(any())).thenAnswer((invocation) async {
    final ops = invocation.positionalArguments.first as List<OutboxOperation>;
    return Right([
      for (final op in ops)
        OperationReply(
          operationId: op.operationId,
          outcome: outcome,
          error: error,
        ),
    ]);
  });
}

/// Батч не доехал целиком (сеть, 5xx) - ни одна операция не получила исхода.
void stubBatchFailure(MockOperationsApi api, Failure failure) {
  when(() => api.send(any())).thenAnswer((_) async => Left(failure));
}
