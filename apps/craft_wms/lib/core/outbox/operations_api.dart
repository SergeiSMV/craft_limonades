import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../constants/api_constants.dart';
import '../error/dio_failure.dart';
import '../error/failure.dart';
import 'outbox_operation.dart';

/// Исход операции на сервере (P2-05).
enum OperationOutcome {
  /// Применена сейчас.
  accepted,

  /// Уже применялась раньше - сервер отбросил повтор по `operation_id`.
  ///
  /// Для очереди это **успех**, а не особый случай: операция сделана, держать её незачем.
  /// Ради этого статуса журнал и заводился - без него повтор финала сессии приезжал бы
  /// отказом «уже закрыта», хотя остатки записаны.
  duplicate,

  /// Отказ по существу: повтор не поможет, нужен разбор человеком.
  rejected;

  /// Разобрать значение из ответа; `null` - статус, которого эта версия приложения не знает.
  static OperationOutcome? fromWire(String wire) => switch (wire) {
    'accepted' => OperationOutcome.accepted,
    'duplicate' => OperationOutcome.duplicate,
    'rejected' => OperationOutcome.rejected,
    _ => null,
  };
}

/// Ответ сервера по одной операции батча.
class OperationReply {
  const OperationReply({
    required this.operationId,
    required this.outcome,
    this.error,
  });

  /// Ключ идемпотентности операции - по нему ответ сопоставляется со строкой очереди.
  final String operationId;

  /// Что сервер с ней сделал.
  final OperationOutcome outcome;

  /// Причина отказа дословно, как её прислал сервер.
  final String? error;
}

/// Транспорт батча операций очереди (P2-05).
///
/// Что: отправляет операции одним запросом и возвращает исход каждой.
/// Зачем: до P2-05 операция уходила «своим» маршрутом (`POST /barcodes`, `DELETE /barcodes/{code}`)
///        без ключа идемпотентности, и сервер не мог отличить повтор от нового дела.
/// Как: `POST /operations` с массивом `{operation_id, kind, payload}`.
///
/// ⚠ Ответов может прийти МЕНЬШЕ, чем отправлено операций: сервер прекращает разбор на первой
/// временной неудаче, чтобы не нарушить порядок. Операции без ответа остаются в очереди - это
/// нормальный исход, а не потеря.
@lazySingleton
class OperationsApi {
  OperationsApi(this._dio);

  final Dio _dio;

  /// Отправить батч. `Left` - запрос не состоялся целиком (сеть, 5xx): вся пачка остаётся
  /// в очереди. `Right` - разобранные ответы, по одному на применённую операцию.
  Future<Either<Failure, List<OperationReply>>> send(
    List<OutboxOperation> operations,
  ) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.operations,
        data: {
          'operations': [
            for (final op in operations)
              {
                'operation_id': op.operationId,
                'kind': op.kind.wire,
                'payload': op.payload,
              },
          ],
        },
      );
      final raw = (resp.data?['results'] as List<dynamic>?) ?? const [];
      final replies = <OperationReply>[];
      for (final item in raw) {
        final map = item as Map<String, dynamic>;
        final outcome = OperationOutcome.fromWire(
          map['status'] as String? ?? '',
        );
        // Незнакомый статус пропускаем: его придумала более новая версия сервера, и гадать
        // о его смысле опаснее, чем оставить операцию в очереди до обновления приложения.
        if (outcome == null) continue;
        replies.add(
          OperationReply(
            operationId: map['operation_id'] as String? ?? '',
            outcome: outcome,
            error: map['error'] as String?,
          ),
        );
      }
      return Right(replies);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
