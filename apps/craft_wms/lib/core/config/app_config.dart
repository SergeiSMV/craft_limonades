import '../constants/api_constants.dart';

/// Конфигурация приложения из dart-define (`--dart-define-from-file=.env`).
///
/// Зачем: один код собирается против разных бэкендов (эмулятор/сервер) без правок —
/// адрес берётся из `.env` (в `.gitignore`, свой на каждой машине/окружении).
class AppConfig {
  /// Базовый URL бэкенда с префиксом `/api/v1/` (прикладной API живёт под ним, ADR-0015).
  /// Значение — из `.env` по ключу [ApiConst.kBaseUrl]; дефолт — локальный эмулятор.
  /// Гарантируем завершающий `/`: маршруты в коде — без ведущего `/` (см. [ApiConst]),
  /// поэтому dio склеивает `baseUrl` + `path` в корректный URL без двойного слэша.
  static String get baseUrl {
    const value = String.fromEnvironment(
      ApiConst.kBaseUrl,
      defaultValue: 'http://10.0.2.2:8080/api/v1/',
    );
    // Срезаем любые завершающие `/` и добавляем ровно один: устойчиво к тому, как
    // записан URL в .env (с/без слэша, случайный двойной), без двойного слэша в запросах.
    return '${value.replaceAll(RegExp(r'/+$'), '')}/';
  }

  /// Политика конфиденциальности (ADHOC-66): страница `privacy.html` веб-портала.
  /// Портал живёт на том же origin, что и API (ADR-0015), поэтому адрес выводится из [baseUrl],
  /// а не задаётся отдельно: боевая сборка откроет страницу прода, сборка стенда — стенда.
  static String get privacyPolicyUrl =>
      Uri.parse(baseUrl).resolve('/privacy.html').toString();

  /// Название склада для шапки ТСД. На пилоте склад один («Шабулина») — берём из dart-define
  /// (`WAREHOUSE_NAME` в `.env`), с дефолтом. ⚠ Плейсхолдер: при мультискладе/привязке устройства
  /// склад должен приходить из профиля/конфига устройства, а не из константы клиента.
  static String get warehouseName =>
      const String.fromEnvironment('WAREHOUSE_NAME', defaultValue: 'Шабулина');
}
