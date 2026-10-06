import 'package:dio/dio.dart';

import '../auth/token_storage.dart';
import '../constants/api_constants.dart';

/// JWT-интерсептор — клиентская пара к middleware бэкенда (P0-04).
///
/// Что: подставляет access-токен в каждый запрос; на 401 молча обновляет токен и повторяет запрос.
/// Зачем: кладовщик не пересканирует бейдж посреди работы, когда access протух.
/// Как: onRequest добавляет заголовок Authorization; onError при 401 дёргает `/auth/refresh`
/// отдельным «голым» Dio (без этого интерсептора — иначе рекурсия), сохраняет новый access
/// и повторяет исходный запрос один раз. Попутно отмечает момент последнего успешного
/// обмена с сервером — по нему ограничен вход без связи (долг 9).
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._storage, this._tokenDio);

  /// Как часто обновлять отметку контакта. Чаще незачем: предел офлайн-входа — сутки,
  /// а запись в зашифрованное хранилище на каждый запрос прохода — лишняя работа.
  static const contactWriteInterval = Duration(minutes: 1);

  /// Когда отметка писалась в этом процессе (null — ещё не писалась).
  DateTime? _contactWrittenAt;

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

  /// Успешный ответ на запрос с токеном — сервер принял сессию: отмечаем контакт.
  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    await _noteContact(response);
    handler.next(response);
  }

  /// Отметить успешный обмен с сервером.
  ///
  /// Что: запоминает момент ответа 2xx на запрос, ушедший с access-токеном.
  /// Зачем: вход без связи разрешён, только пока последний такой обмен свежий (долг 9) —
  ///        иначе терминалу с отозванным доступом хватало бы живого refresh-токена (30 дней).
  /// Как: считается только запрос с заголовком `Authorization`: ответ без токена (вход,
  ///      пробы) не доказывает, что сервер принял именно эту сессию. Пишем не чаще
  ///      [contactWriteInterval].
  Future<void> _noteContact(Response<dynamic> response) async {
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) return;
    if (response.requestOptions.headers['Authorization'] == null) return;
    final now = DateTime.now();
    final last = _contactWrittenAt;
    if (last != null && now.difference(last) < contactWriteInterval) return;
    _contactWrittenAt = now;
    await _storage.saveLastContact(now);
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
        ApiConst.refreshToken,
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
      // Повтор идёт мимо onResponse — контакт отмечаем здесь.
      await _noteContact(clone);
      return handler.resolve(clone);
    } on DioException {
      // refresh тоже протух/невалиден — чистим токены; UI уйдёт на экран входа.
      await _storage.clear();
      return handler.next(err);
    }
  }
}
