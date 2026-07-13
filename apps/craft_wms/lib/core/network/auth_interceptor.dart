import 'package:dio/dio.dart';

import '../auth/token_storage.dart';

/// JWT-интерсептор — клиентская пара к middleware бэкенда (P0-04).
///
/// Что: подставляет access-токен в каждый запрос; на 401 молча обновляет токен и повторяет запрос.
/// Зачем: кладовщик не пересканирует бейдж посреди работы, когда access протух.
/// Как: onRequest добавляет заголовок Authorization; onError при 401 дёргает `/auth/refresh`
/// отдельным «голым» Dio (без этого интерсептора — иначе рекурсия), сохраняет новый access
/// и повторяет исходный запрос один раз.
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._storage, this._tokenDio);

  /// Хранилище токенов.
  final TokenStorage _storage;

  /// Dio без AuthInterceptor — для refresh и повтора запроса.
  final Dio
  _tokenDio; // Dio без AuthInterceptor — для refresh и повтора запроса

  /// Ключ для отметки повторного запроса.
  static const _retriedKey = 'retried';

  /// Перед запросом добавляет заголовок Authorization.
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final access = await _storage.readAccess();
    if (access != null) {
      options.headers['Authorization'] = 'Bearer $access';
    }
    handler.next(options);
  }

  /// При 401 дёргает `/auth/refresh` отдельным «голым» Dio (без этого интерсептора — иначе рекурсия),
  /// сохраняет новый access и повторяет исходный запрос один раз.
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    /// Проверяем, является ли ошибка 401.
    final is401 = err.response?.statusCode == 401;

    /// Проверяем, был ли уже повторный запрос.
    final alreadyRetried = err.requestOptions.extra[_retriedKey] == true;

    // Обновляем токен только на 401 и только один раз, иначе пропускаем ошибку дальше.
    if (!is401 || alreadyRetried) {
      return handler.next(err);
    }

    /// Читаем refresh-токен из хранилища.
    final refresh = await _storage.readRefresh();

    /// Если refresh-токен не найден, пропускаем ошибку дальше.
    if (refresh == null) {
      return handler.next(err);
    }

    /// Пытаемся получить новый access по refresh-токену.
    try {
      // 1. Получаем новый access по refresh-токену.
      final resp = await _tokenDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh': refresh},
      );

      /// Если новый access не найден, чистим токены и пропускаем ошибку дальше.
      final newAccess = resp.data?['access'] as String?;
      if (newAccess == null) {
        await _storage.clear();
        return handler.next(err);
      }

      /// Сохраняем новый access в хранилище.
      await _storage.saveAccess(newAccess);

      // 2. Повторяем исходный запрос с новым токеном (пометка retried защищает от цикла).
      final req = err.requestOptions;
      req.headers['Authorization'] = 'Bearer $newAccess';
      req.extra[_retriedKey] = true;
      final clone = await _tokenDio.fetch<dynamic>(req);
      return handler.resolve(clone);
    } on DioException {
      // refresh тоже протух/невалиден — чистим токены; UI уйдёт на экран входа.
      await _storage.clear();
      return handler.next(err);
    }
  }
}
