/// Константы для API.
///
/// Маршруты — БЕЗ ведущего `/`, а `BASE_URL` — С завершающим `/` (`.../api/v1/`).
/// Это согласованная пара для dio: `baseUrl` + `path` даёт корректный URL без двойного слэша.
abstract final class ApiConst {
  /// Имя dart-define-ключа с базовым URL API. Значение приходит из `.env`
  /// (`--dart-define-from-file=.env`), а не хардкодится в коде.
  static const String kBaseUrl = 'BASE_URL';

  ///**POST** - запрос на авторизацию по бейджу пользователя
  static const String loginByBadge = 'auth/login';

  ///**POST** - авторизация по логину/паролю (admin/оператор — веб-портал, смартфон)
  static const String loginByPassword = 'auth/login/password';

  ///**POST** - обновление access-токена по refresh
  static const String refreshToken = 'auth/refresh';

  ///**GET** - профиль текущего пользователя (защищённый)
  static const String me = 'auth/me';

  ///**POST** - импорт номенклатуры из `.xls`-выгрузки 1С (multipart, admin-only)
  static const String importGoods = 'import/goods';
}
