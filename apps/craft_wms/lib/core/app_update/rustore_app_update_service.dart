import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rustore_update/flutter_rustore_update.dart';
import 'package:injectable/injectable.dart';

import '../config/app_config.dart';
import 'app_update_service.dart';

/// Обновление из RuStore через `flutter_rustore_update` (ADHOC-69).
///
/// Как: [check] - `info()`; [startDownload] - тихий сценарий `silent()` (скачивание в фоне без
///      окон RuStore); [install] - `completeUpdateFlexible()`: RuStore показывает окно установки
///      и после неё запускает приложение заново. `completeUpdateSilent()` не берём - он просто
///      закрывает приложение, и работник не понял бы, куда оно делось.
///
/// Ошибки SDK приходят из платформенного канала как [PlatformException], где `message` - имя
/// класса ошибки (`RuStoreNotInstalledException`, `RuStoreUserUnauthorizedException`, …). Здесь
/// они переводятся в [AppUpdateUnavailable], чтобы выше SDK никто не разбирал его ошибки.
///
/// Не проверяем: веб-портал, сборку стенда (её нет в RuStore) и демо-режим (показ системы,
/// посреди показа новой версии не нужно).
@LazySingleton(as: AppUpdateService)
class RustoreAppUpdateService implements AppUpdateService {
  @override
  bool get supported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      !AppConfig.isStand &&
      !AppConfig.isDemo;

  @override
  Future<AppUpdateAvailability> check() async {
    final info = await _guard(RustoreUpdateClient.info);
    if (info.installStatusValue == InstallStatus.downloaded) {
      return AppUpdateAvailability.downloaded;
    }
    return switch (info.updateAvailabilityValue) {
      UpdateAvailability.available => AppUpdateAvailability.available,
      UpdateAvailability.inProgress => AppUpdateAvailability.downloading,
      UpdateAvailability.notAvailable ||
      UpdateAvailability.unknown => AppUpdateAvailability.none,
    };
  }

  @override
  Stream<AppUpdateDownloadEvent> get downloadEvents => RustoreUpdateClient
      .stateStream
      .map(_event)
      .where((e) => e != null)
      .map((e) => e!);

  @override
  Future<void> startDownload() async {
    final response = await _guard(RustoreUpdateClient.silent);
    // Тихий сценарий отвечает только OK (задача на скачивание принята) или ошибкой.
    if (response.code != ACTIVITY_RESULT_OK) {
      throw AppUpdateUnavailable('silent code ${response.code}');
    }
  }

  @override
  Future<void> install() => _guard(RustoreUpdateClient.completeUpdateFlexible);

  /// Статус скачивания SDK → событие контракта; промежуточные статусы пропускаем.
  AppUpdateDownloadEvent? _event(RequestResponse state) =>
      switch (state.installStatusValue) {
        InstallStatus.downloading ||
        InstallStatus.pending => AppUpdateDownloadEvent.downloading,
        InstallStatus.downloaded => AppUpdateDownloadEvent.downloaded,
        InstallStatus.failed => AppUpdateDownloadEvent.failed,
        InstallStatus.unknown || InstallStatus.installing => null,
      };

  /// Вызов SDK с переводом его ошибок в [AppUpdateUnavailable].
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      // message - имя класса ошибки, code - её toString() с текстом SDK: в журнал оба.
      throw AppUpdateUnavailable('${e.message} | ${e.code}');
    } on MissingPluginException catch (e) {
      throw AppUpdateUnavailable(e.toString());
    }
  }
}
