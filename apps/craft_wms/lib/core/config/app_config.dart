/// Конфигурация приложения из --dart-define.
///
/// Зачем: один APK работает против разных бэкендов (эмулятор/сервер) без пересборки кода —
/// адрес передаётся при запуске (`--dart-define=BASE_URL=...`).
class AppConfig {
  /// Базовый URL бэкенда — включает префикс `/api/v1` (прикладной API живёт под ним, ADR-0015).
  /// Пути в коде относительные (`/auth/login`, `/import/goods`), поэтому версия задаётся здесь.
  /// Дефолт `10.0.2.2` — это localhost хост-машины из Android-эмулятора.
  /// Для реального ТСД укажите адрес сервера через --dart-define, напр.
  /// `--dart-define=BASE_URL=https://craft.skogi.ru/api/v1`.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://10.0.2.2:8080/api/v1',
  );
}
