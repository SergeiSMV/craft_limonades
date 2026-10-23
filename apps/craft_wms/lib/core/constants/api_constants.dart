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

  ///**GET** - текущие задания склада: пул и свои взятые, с позициями (P5-02-1).
  static const String tasks = 'tasks';

  ///**GET** - лента «Завершённые»: курсор и фильтры (P5-02-1).
  static const String tasksCompleted = 'tasks/completed';

  ///**GET** - варианты фильтра ленты по исполнителю (P5-02-1).
  static const String tasksExecutors = 'tasks/executors';

  ///**GET** - карточка задания с заходами: `tasks/{id}`.
  static String taskById(String id) => 'tasks/$id';

  ///**GET** - открытые проблемы склада на ТСД (ADHOC-35), свежие первыми
  static const String problemsCurrent = 'problems/current';

  ///**GET** - лента решённых проблем склада на ТСД (ADHOC-34): from, to, курсор
  ///before_resolved_at + before_id, limit
  static const String problemsResolved = 'problems/resolved';

  /// История перемещений всего склада (ADHOC-28): лента, курсор и фильтр — query.
  static const String movements = 'movements';

  /// Варианты фильтра истории перемещений по исполнителю.
  static const String movementsExecutors = 'movements/executors';

  /// Запись истории перемещений со строками.
  static String movementById(String id) => 'movements/$id';

  /// Справочник внутренних складов (P6-07-1): «Основной», «Брак», «Изолятор» …
  static const String internalWarehouses = 'internal-warehouses';

  /// Внутренний склад — переименовать, скрыть, удалить (ADHOC-29, admin).
  static String internalWarehouseById(String id) => 'internal-warehouses/$id';

  ///**GET** - «Проблемы склада» для офиса (P6-07-3, admin): открытые сверху.
  static const String problems = 'problems';

  ///**POST** - «Провести» решение по проблеме (204): `problems/{id}/resolve`.
  static String problemResolve(String id) => 'problems/$id/resolve';

  ///**POST** - взять задание (204; 409 — у другого или выполнено): `tasks/{id}/take`.
  static String taskTake(String id) => 'tasks/$id/take';

  ///**POST** - отказаться от задания (204): `tasks/{id}/release`.
  static String taskRelease(String id) => 'tasks/$id/release';

  ///**GET** - снимок содержимого склада для кэша ТСД, живые короба и россыпь (P5-05): `contents/snapshot`.
  static const String contentsSnapshot = 'contents/snapshot';

  ///**GET** - содержимое ячейки, короба и россыпь (P5-05): `cells/{id}/contents`.
  static String cellContents(String id) => 'cells/$id/contents';

  ///**GET** - карточка короба, где лежит и что внутри (P5-05): `load-units/{id}/card`.
  static String loadUnitCard(String id) => 'load-units/$id/card';

  ///**GET** - короба по короткому коду с ярлыка, живые и нет (P5-05-1): `load-units?code=…`.
  static const String loadUnits = 'load-units';

  ///**GET** - история короба, приёмка и переносы (P5-05-1): `load-units/{id}/history`.
  static String loadUnitHistory(String id) => 'load-units/$id/history';

  ///**POST** - скан марки «Честного знака» или кода короба: данные ЧЗ, товар, место в WMS,
  /// состав (CZ-04): `cz/scan`. Код — в теле: в КИ бывают `/`, `%`, `"`.
  static const String czScan = 'cz/scan';

  ///**PATCH** - признак «маркируемый» у товара, только admin (CZ-05): `goods/{id}/cz-marked`.
  static String goodCzMarked(String id) => 'goods/$id/cz-marked';
}
