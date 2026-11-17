import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Записывающий фейковый HttpClientAdapter для тестов dio.
///
/// Что: возвращает заранее заданные ответы по ключу «METHOD path» и запоминает
///      все прошедшие запросы (для проверки заголовков/повторов).
/// Зачем: детерминированный контроль над ответами и ошибками без внешних моков -
///      в т.ч. корректно прикрепляет `response` к DioException на 4xx/5xx.
/// Как: билдер ответа может вернуть [ResponseBody] (Dio сам бросит на не-2xx с
///      прикреплённым response) либо бросить [DioException] (эмуляция «нет сети»).
class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(this.responses);

  final Map<String, ResponseBody Function(RequestOptions)> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final builder = responses['${options.method} ${options.path}'];
    if (builder == null) return ResponseBody.fromString('{}', 404);
    return builder(options);
  }

  @override
  void close({bool force = false}) {}
}

/// JSON-ответ с заданным статусом и content-type (чтобы Dio декодировал тело).
ResponseBody jsonResponse(Map<String, dynamic> body, int status) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
