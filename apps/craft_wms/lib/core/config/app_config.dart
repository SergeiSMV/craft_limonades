/// Конфигурация приложения из --dart-define.
///
/// Зачем: один APK работает против разных бэкендов (эмулятор/сервер) без пересборки кода —
/// адрес передаётся при запуске (`--dart-define=BASE_URL=...`).
class AppConfig {
  /// Базовый URL бэкенда.
  /// Дефолт `10.0.2.2` — это localhost хост-машины из Android-эмулятора.
  /// Для реального ТСД укажите IP сервера через --dart-define.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );
}
