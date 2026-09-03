import 'package:dio/dio.dart';

import 'failure.dart';

/// Перевод ошибки dio в доменную [Failure] — общий для всех репозиториев.
///
/// Что: код ответа и текст причины от сервера превращаются в типизированный отказ.
/// Зачем: правило было продублировано в каждом репозитории и разошлось. Справочники теряли
///        причину (`Failure.server(code)` без текста), а ввод остатков её сохранял — при том
///        что сервер присылает её одинаково, полем `error` в теле ответа. С появлением очереди
///        операций (P2-03) потеря стала заметной: в отклонённой операции вместо объяснения
///        оставался голый код.
/// Как: 401 — истёкшая сессия; любой другой код — отказ сервера с его же текстом, если он есть;
///      кода нет вовсе (обрыв, таймаут) — отсутствие связи.
Failure mapDioError(DioException e) {
  final code = e.response?.statusCode;
  if (code == 401) return const Failure.auth();
  if (code != null) {
    return Failure.server(code, serverMessage(e.response?.data));
  }
  return const Failure.network();
}

/// Текст причины из тела ответа, если сервер его прислал.
///
/// Тело разбирается защитно: на 5xx и от промежуточного прокси вместо JSON может прийти HTML
/// или пустота, и падать на разборе ошибки — худший момент для падения.
String? serverMessage(Object? data) {
  if (data is! Map) return null;
  final message = data['error'];
  return message is String && message.isNotEmpty ? message : null;
}
