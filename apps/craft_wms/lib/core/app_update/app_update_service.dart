/// Обновление приложения ТСД из магазина (ADHOC-69) - контракт без привязки к SDK.
///
/// Что: проверить, есть ли новая версия, скачать её в фоне и поставить.
/// Зачем: кубит экрана входа и тесты не знают про RuStore - SDK живёт только в реализации
///        (`RustoreAppUpdateService`), его можно заменить, не трогая экран.
library;

/// Что известно об обновлении после проверки.
enum AppUpdateAvailability {
  /// Новой версии нет (или магазин не знает о приложении).
  none,

  /// Новая версия есть, скачивание ещё не начато.
  available,

  /// Скачивание уже идёт (начато раньше, например при прошлом показе экрана входа).
  downloading,

  /// Новая версия скачана и ждёт установки.
  downloaded,
}

/// Ход фонового скачивания.
enum AppUpdateDownloadEvent { downloading, downloaded, failed }

/// Магазин отказал: нет RuStore, не выполнен вход в RuStore, приложение не найдено и т.п.
///
/// [reason] - имя ошибки SDK (например `RuStoreUserUnauthorizedException`) или код ошибки
/// скачивания: пишется в журнал приложения, работнику не показывается.
class AppUpdateUnavailable implements Exception {
  const AppUpdateUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'AppUpdateUnavailable($reason)';
}

/// Источник обновлений приложения.
abstract interface class AppUpdateService {
  /// Можно ли вообще проверять обновление в этой сборке и в этом режиме.
  bool get supported;

  /// Есть ли новая версия. Отказ магазина - [AppUpdateUnavailable].
  Future<AppUpdateAvailability> check();

  /// Ход скачивания. Подписываться до [startDownload], чтобы не пропустить «скачано».
  Stream<AppUpdateDownloadEvent> get downloadEvents;

  /// Начать фоновое скачивание без окон магазина. Отказ - [AppUpdateUnavailable].
  Future<void> startDownload();

  /// Поставить скачанную версию. Магазин показывает окно установки, после неё приложение
  /// запускается заново. Отказ - [AppUpdateUnavailable].
  Future<void> install();
}
