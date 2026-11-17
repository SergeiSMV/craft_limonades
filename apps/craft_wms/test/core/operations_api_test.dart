import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

/// Операция очереди для теста транспорта.
OutboxOperation op(String id, {OutboxKind kind = OutboxKind.bindBarcode}) {
  final now = DateTime(2026, 9, 8);
  return OutboxOperation(
    seq: 1,
    operationId: id,
    kind: kind,
    payload: const {'good_id': 'g1', 'barcode': '4607044662964'},
    status: OutboxStatus.pending,
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  OperationsApi apiWith(
    Map<String, ResponseBody Function(RequestOptions)> responses, {
    RecordingAdapter? adapter,
  }) {
    dio.httpClientAdapter = adapter ?? RecordingAdapter(responses);
    return OperationsApi(dio);
  }

  group('формат запроса', () {
    test('операция едет ключом идемпотентности, типом и телом', () async {
      final adapter = RecordingAdapter({
        'POST ${ApiConst.operations}': (_) => jsonResponse({
          'results': [
            {'operation_id': 'op-1', 'status': 'accepted', 'result': {}},
          ],
        }, 200),
      });
      final api = apiWith(const {}, adapter: adapter);

      await api.send([op('op-1')]);

      final sent = adapter.requests.single;
      expect(sent.method, 'POST');
      expect(sent.path, ApiConst.operations);
      final body = sent.data as Map<String, dynamic>;
      final ops = body['operations'] as List<dynamic>;
      final first = ops.single as Map<String, dynamic>;
      expect(
        first['operation_id'],
        'op-1',
        reason: 'без ключа сервер не отличит повтор от нового дела',
      );
      expect(
        first['kind'],
        'bind_barcode',
        reason: 'тип едет полем, а не адресом ручки',
      );
      expect(first['payload'], {'good_id': 'g1', 'barcode': '4607044662964'});
    });
  });

  group('разбор ответа', () {
    test('accepted и duplicate разбираются, порядок сохраняется', () async {
      final api = apiWith({
        'POST ${ApiConst.operations}': (_) => jsonResponse({
          'results': [
            {'operation_id': 'op-1', 'status': 'accepted'},
            {'operation_id': 'op-2', 'status': 'duplicate'},
          ],
        }, 200),
      });

      final res = await api.send([op('op-1'), op('op-2')]);

      expect(res.isRight, isTrue);
      expect(res.right.map((r) => r.operationId), ['op-1', 'op-2']);
      expect(res.right.first.outcome, OperationOutcome.accepted);
      expect(res.right.last.outcome, OperationOutcome.duplicate);
    });

    test('rejected несёт причину сервера дословно', () async {
      final api = apiWith({
        'POST ${ApiConst.operations}': (_) => jsonResponse({
          'results': [
            {
              'operation_id': 'op-1',
              'status': 'rejected',
              'error': 'barcode bound to another good',
            },
          ],
        }, 200),
      });

      final res = await api.send([op('op-1')]);

      expect(res.right.single.outcome, OperationOutcome.rejected);
      expect(res.right.single.error, 'barcode bound to another good');
    });

    test('незнакомый статус пропускается, а не толкуется наугад', () async {
      final api = apiWith({
        'POST ${ApiConst.operations}': (_) => jsonResponse({
          'results': [
            {'operation_id': 'op-1', 'status': 'quarantined'},
            {'operation_id': 'op-2', 'status': 'accepted'},
          ],
        }, 200),
      });

      final res = await api.send([op('op-1'), op('op-2')]);

      expect(
        res.right.map((r) => r.operationId),
        ['op-2'],
        reason: 'статус придумала более новая версия сервера - гадать нельзя',
      );
    });

    test('5xx → Failure.server, вся пачка остаётся в очереди', () async {
      final api = apiWith({
        'POST ${ApiConst.operations}': (_) => jsonResponse({}, 503),
      });

      final res = await api.send([op('op-1')]);

      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  group('OutboxSender: перевод исхода', () {
    /// Транспорт, отвечающий одним статусом на любую операцию.
    OperationsApi replying(String status, {String? error}) => apiWith({
      'POST ${ApiConst.operations}': (_) => jsonResponse({
        'results': [
          <String, dynamic>{
            'operation_id': 'op-1',
            'status': status,
            'error': ?error,
          },
        ],
      }, 200),
    });

    test('duplicate - успех: дело сделано, держать операцию незачем', () async {
      final sender = OutboxSender(replying('duplicate'));

      final res = await sender.send(op('op-1'));

      expect(
        res.isRight,
        isTrue,
        reason:
            'иначе повтор финала сессии осел бы на экране разбора '
            'как ошибка, хотя остатки записаны',
      );
    });

    test('rejected - отказ с причиной, повторять нельзя', () async {
      final sender = OutboxSender(
        replying('rejected', error: 'barcode bound to another good'),
      );

      final res = await sender.send(op('op-1'));

      expect(res.isLeft, isTrue);
      expect(res.left, isA<RejectedFailure>());
      expect(
        (res.left as RejectedFailure).reason,
        'barcode bound to another good',
      );
    });

    test('пустой ответ - сервер не дошёл до операции, пробуем позже', () async {
      final api = apiWith({
        'POST ${ApiConst.operations}': (_) =>
            jsonResponse({'results': <dynamic>[]}, 200),
      });
      final sender = OutboxSender(api);

      final res = await sender.send(op('op-1'));

      expect(res.isLeft, isTrue);
      expect(
        res.left,
        isA<NetworkFailure>(),
        reason:
            'операция должна остаться в очереди, а не считаться отклонённой',
      );
    });
  });
}
