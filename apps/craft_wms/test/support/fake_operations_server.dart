import 'dart:convert';
import 'dart:typed_data';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:dio/dio.dart';

/// Фейковый сервер приёма операций — ведёт себя как настоящий бэкенд (P2-08).
///
/// Что: адаптер dio, который разбирает батч, помнит применённые `operation_id` и отвечает
///      `accepted` / `duplicate` / `rejected` по тем же правилам, что Go-сервер.
/// Зачем: сквозной тест клиентской цепи бессмысленен против заглушки, отвечающей заранее
///        заготовленным телом: она подтвердит любой формат запроса, в том числе неверный.
///        Здесь ответ ЗАВИСИТ от присланных операций, а дедуп — настоящий.
/// Как: [offline] гасит связь (dio получает ошибку соединения, как при обрыве);
///      [applied] показывает, что сервер реально применил.
///
/// Контракт скопирован не с кода, а с проверенного HTTP-теста бэкенда
/// (`operations_http_test.go`): те же имена полей и те же статусы.
class FakeOperationsServer implements HttpClientAdapter {
  /// Связь оборвана — сервер недостижим.
  bool offline = false;

  /// `operation_id`, по которым эффект уже применён.
  final Set<String> applied = {};

  /// `barcode` → `good_id`: то, что «лежит в справочнике» сервера.
  final Map<String, String> barcodes = {};

  /// Сколько раз батч доходил до сервера — для проверки «очередь ушла одним запросом».
  int requests = 0;

  /// Тело последнего батча — для снятия эталона формата.
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'нет связи',
      );
    }
    if (options.path != ApiConst.operations) {
      return ResponseBody.fromString('{}', 404);
    }
    requests++;

    final body = options.data as Map<String, dynamic>;
    lastBody = body;
    final ops = (body['operations'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final results = [for (final op in ops) _apply(op)];

    return ResponseBody.fromString(
      jsonEncode({'results': results}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  /// Применить одну операцию с дедупом по ключу идемпотентности.
  Map<String, dynamic> _apply(Map<String, dynamic> op) {
    final id = op['operation_id'] as String;
    if (applied.contains(id)) {
      return {
        'operation_id': id,
        'status': 'duplicate',
        'result': <String, dynamic>{},
      };
    }
    final payload = op['payload'] as Map<String, dynamic>;
    final code = payload['barcode'] as String?;

    switch (op['kind']) {
      case 'bind_barcode':
        final goodId = payload['good_id'] as String;
        final owner = barcodes[code];
        // Тот же ШК за другим товаром — отказ по существу, как на сервере.
        if (owner != null && owner != goodId) {
          return {
            'operation_id': id,
            'status': 'rejected',
            'error': 'barcode bound to another good',
          };
        }
        barcodes[code!] = goodId;
      case 'unbind_barcode':
        barcodes.remove(code);
      default:
        return {
          'operation_id': id,
          'status': 'rejected',
          'error': 'unknown operation kind',
        };
    }
    applied.add(id);
    return {
      'operation_id': id,
      'status': 'accepted',
      'result': <String, dynamic>{},
    };
  }

  @override
  void close({bool force = false}) {}
}
