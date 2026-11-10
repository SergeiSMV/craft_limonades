import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../outbox/outbox_repository.dart';
import 'app_update_service.dart';

/// Что показывать об обновлении.
enum AppUpdateState {
  /// Ничего: обновления нет, оно ещё качается или магазин отказал.
  hidden,

  /// Новая версия скачана - видна кнопка «Обновить приложение».
  ready,

  /// Установка запущена, окно магазина на экране.
  installing,
}

/// Итог нажатия «Обновить приложение».
enum AppUpdateInstallResult {
  /// Установка запущена - дальше окно магазина и перезапуск приложения.
  started,

  /// В очереди есть неотправленные операции - сначала их отправить.
  queueNotEmpty,

  /// Магазин не смог поставить обновление.
  failed,
}

/// Обновление приложения ТСД (ADHOC-69) - одно на всё приложение.
///
/// Что: проверяет новую версию, тихо скачивает её в фоне и, когда она скачана, показывает
///      кнопку. Установку запускает только при пустой очереди операций.
/// Где: проверку и кнопку дают только экран входа и главное меню. Ни там, ни там никто не стоит
///      посреди операции: приёмка, размещение, сборка открываются отдельными экранами поверх
///      меню, и внутри них установка не запускается.
/// Когда: при показе этих экранов, при возврате в меню из раздела и при выходе приложения на
///      передний план - не чаще [checkInterval]. Сеанс живёт до 30 дней (refresh-токен), поэтому
///      ждать экрана входа нельзя: терминал месяцами не увидел бы новую версию.
/// Почему одно на приложение: скачивание идёт в фоне дольше одного экрана, а «скачано» должно
///      дожить до перехода между входом и меню.
/// Как: любой отказ магазина (нет RuStore, нет входа в RuStore, нет обновления) - запись в
///      журнал и состояние [AppUpdateState.hidden]: работнику ошибок не показываем.
@lazySingleton
class AppUpdateCubit extends Cubit<AppUpdateState> {
  AppUpdateCubit(this._service, this._outbox, this._talker)
    : super(AppUpdateState.hidden);

  /// Как часто спрашивать магазин: версии выходят редко, а каждый запрос - сеть и батарея ТСД.
  static const checkInterval = Duration(hours: 3);

  final AppUpdateService _service;
  final OutboxRepository _outbox;
  final Talker _talker;

  StreamSubscription<AppUpdateDownloadEvent>? _downloads;

  /// Время прошлой проверки; `null` - проверки ещё не было.
  DateTime? _lastCheck;

  /// Идёт ли проверка прямо сейчас (экраны могут попросить её одновременно).
  bool _checking = false;

  /// Проверить обновление и, если оно есть, начать скачивание.
  ///
  /// [now] - для тестов. Повторный вызов раньше [checkInterval], во время проверки, во время
  /// скачивания или при уже скачанной версии ничего не делает.
  Future<void> check({DateTime? now}) async {
    if (!_service.supported || _checking || _downloads != null) return;
    if (state != AppUpdateState.hidden) return;
    final at = now ?? DateTime.now();
    final last = _lastCheck;
    if (last != null && at.difference(last) < checkInterval) return;
    _lastCheck = at;
    _checking = true;
    try {
      final availability = await _service.check();
      _talker.info('Обновление приложения: $availability');
      switch (availability) {
        case AppUpdateAvailability.none:
          return;
        case AppUpdateAvailability.downloaded:
          _emit(AppUpdateState.ready);
        case AppUpdateAvailability.downloading:
          _listenDownloads();
        case AppUpdateAvailability.available:
          // Подписка раньше запуска: иначе быстрое «скачано» пролетит мимо.
          _listenDownloads();
          await _service.startDownload();
      }
    } on AppUpdateUnavailable catch (e) {
      _talker.info('Обновление приложения недоступно: ${e.reason}');
      await _stopListening();
    } finally {
      _checking = false;
    }
  }

  /// Поставить скачанную версию, если очередь операций пуста.
  Future<AppUpdateInstallResult> install() async {
    final pending = await _outbox.pendingCount();
    if (pending > 0) {
      _talker.info('Обновление отложено: в очереди $pending операций');
      return AppUpdateInstallResult.queueNotEmpty;
    }
    _emit(AppUpdateState.installing);
    try {
      await _service.install();
      return AppUpdateInstallResult.started;
    } on AppUpdateUnavailable catch (e) {
      _talker.warning('Обновление приложения не установлено: ${e.reason}');
      _emit(AppUpdateState.ready);
      return AppUpdateInstallResult.failed;
    }
  }

  /// Следить за фоновым скачиванием: «скачано» - кнопка, ошибка - журнал и новая попытка
  /// со следующей проверкой.
  void _listenDownloads() {
    _downloads ??= _service.downloadEvents.listen(
      (event) {
        switch (event) {
          case AppUpdateDownloadEvent.downloaded:
            _emit(AppUpdateState.ready);
            unawaited(_stopListening());
          case AppUpdateDownloadEvent.failed:
            _talker.info('Обновление приложения: ошибка скачивания');
            unawaited(_stopListening());
          case AppUpdateDownloadEvent.downloading:
            break;
        }
      },
      onError: (Object e) =>
          _talker.info('Обновление приложения: поток статусов - $e'),
    );
  }

  Future<void> _stopListening() async {
    final downloads = _downloads;
    _downloads = null;
    await downloads?.cancel();
  }

  void _emit(AppUpdateState next) {
    if (!isClosed) emit(next);
  }

  @override
  Future<void> close() async {
    await _stopListening();
    return super.close();
  }
}
