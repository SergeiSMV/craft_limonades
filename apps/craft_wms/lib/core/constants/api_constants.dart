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

  ///**GET** - список/поиск товаров (q, group_id, supplier_id, limit, offset)
  static const String goods = 'goods';

  ///**GET** - все группы номенклатуры (дерево)
  static const String nomenclatureGroups = 'nomenclature-groups';

  ///**GET** - поставщики (опциональный q)
  static const String suppliers = 'suppliers';

  ///**GET** - остатки (good_id — где лежит товар; cell_id — что в ячейке)
  static const String stock = 'stock';

  /// Путь карточки товара по id: `goods/{id}`.
  static String goodById(String id) => 'goods/$id';
}
