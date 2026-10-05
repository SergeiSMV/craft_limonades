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

  ///**POST** - импорт ячеек склада из `.xlsx` (multipart, admin-only)
  static const String importCells = 'import/cells';

  ///**GET** - PDF-этикетки ячеек склада (query `warehouse`, admin-only, ответ — bytes)
  static const String cellLabelsPdf = 'cells/labels.pdf';

  ///**GET** - список/поиск товаров (q, group_id, supplier_id, limit, offset)
  static const String goods = 'goods';

  ///**GET** - все группы номенклатуры (дерево)
  static const String nomenclatureGroups = 'nomenclature-groups';

  ///**GET** - поставщики (опциональный q)
  static const String suppliers = 'suppliers';

  ///**GET** - остатки (good_id — где лежит товар; cell_id — что в ячейке)
  static const String stock = 'stock';

  ///**GET** - список/поиск ячеек (q по адресу, warehouse_id, is_floor)
  static const String cells = 'cells';

  ///**POST** - батч операций офлайн-очереди с дедупом по `operation_id` (P2-05)
  static const String operations = 'operations';

  ///**POST** - открыть сессию ввода остатков (P-FastStart)
  static const String stockEntrySessions = 'stock-entry/sessions';

  /// Путь карточки товара по id: `goods/{id}`.
  static String goodById(String id) => 'goods/$id';

  ///**POST** - привязать ШК к товару (201; 409 — ШК уже за другим товаром): `barcodes`.
  static const String barcodes = 'barcodes';

  ///**GET** - товар по штрихкоду (404, если ШК не привязан) · **DELETE** - отвязать ШК (204, P-FS-12): `barcodes/{code}`.
  static String barcodeByCode(String code) => 'barcodes/$code';

  ///**GET** - все ШК товара (секция «Штрихкоды» карточки, P-FS-12): `goods/{id}/barcodes`.
  static String goodBarcodes(String id) => 'goods/$id/barcodes';

  ///**POST** - выдать товару внутренний EAN-13 (P4-07; идемпотентно — повтор вернёт тот же код): `goods/{id}/barcode`.
  static String goodInternalBarcode(String id) => 'goods/$id/barcode';

  ///**POST** - checkpoint ячейки в сессии ввода: `stock-entry/sessions/{id}/cells`.
  static String stockEntryCells(String id) => 'stock-entry/sessions/$id/cells';

  ///**POST** - финал сессии ввода → запись в stock: `stock-entry/sessions/{id}/finalize`.
  static String stockEntryFinalize(String id) =>
      'stock-entry/sessions/$id/finalize';

  ///**GET** - рабочий список документов оператора: необработанные сверху (P3-02).
  static const String documents = 'documents';

  ///**GET** - .xlsx документа; попутно отмечает скачивание: `documents/{id}/file.xlsx`.
  static String documentFile(String id) => 'documents/$id/file.xlsx';

  ///**POST** - «Выполнено»: документ занесён в 1С (204): `documents/{id}/done`.
  static String documentDone(String id) => 'documents/$id/done';

  ///**GET** - журнал документа: кто и когда что делал (P3-03): `documents/{id}/events`.
  static String documentEvents(String id) => 'documents/$id/events';
}
