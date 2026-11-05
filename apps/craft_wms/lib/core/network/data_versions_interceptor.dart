import 'package:dio/dio.dart';

import '../sync/data_versions.dart';

/// Читает версии данных из каждого ответа сервера (ADHOC-60) — и удачного, и с ошибкой: 4xx
/// тоже несёт заголовок.
///
/// Стоит на обоих Dio: повтор запроса после обновления токена идёт через `tokenDio`, и его
/// ответ до перехватчиков основного Dio не доходит.
class DataVersionsInterceptor extends Interceptor {
  DataVersionsInterceptor(this._versions);

  /// Имя заголовка ответа; Dio сравнивает имена без учёта регистра.
  static const header = 'x-data-versions';

  final DataVersions _versions;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _versions.observe(response.headers.value(header));
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _versions.observe(err.response?.headers.value(header));
    handler.next(err);
  }
}
