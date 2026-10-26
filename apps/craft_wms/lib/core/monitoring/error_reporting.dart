import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../auth/auth_cubit.dart';
import '../config/app_config.dart';

/// Какое приложение шлёт событие — тег `app` в Bugsink: у ТСД и портала один проект.
enum ReportingApp { tsd, portal }

/// Отправка ошибок приложения в Bugsink (ADHOC-47, долг 34).
///
/// Что: необработанные исключения Flutter и Dart, исключения, которые ловит `talker`, и падения
/// нативной части Android уходят событиями в проект `app` — через свой бэкенд: он пересылает
/// конверт в Bugsink с ключом проекта.
/// Зачем: о сбое на складе узнавали со слов кладовщика, без стека и версии сборки.
/// Как: `sentry_flutter` с DSN, построенным из адреса API ([dsnFor]): ключ в нём фиктивный,
/// настоящий знает только сервер. Включается только в релизной сборке — отладка шумела бы.
/// В событии — версия сборки (SDK берёт сама), приложение, окружение, пользователь (id и роль).
/// Печать в консоль хлебными крошками не собирается: логгер dio печатает тела запросов,
/// а в теле входа — секрет бейджа. Сессии и замеры производительности не отправляются.
abstract final class ErrorReporting {
  /// Фиктивный ключ DSN: бэкенд его отбрасывает и ставит ключ проекта.
  static const _publicKey = 'wms';

  /// Проект в DSN — путь приёма на бэкенде `/api/1/envelope/` (`handler.ClientErrorsProject`).
  static const _project = '1';

  /// DSN приложения из адреса API. Адрес относительный (портал: `/api/v1/`) — от адреса
  /// страницы [page]; события уходят на тот же сервер, что и запросы.
  @visibleForTesting
  static String dsnFor(String baseUrl, {Uri? page}) {
    final api = (page ?? Uri.base).resolve(baseUrl);
    return '${api.scheme}://$_publicKey@${api.authority}/$_project';
  }

  /// Запустить приложение [appRunner] с отправкой ошибок. В отладочной сборке — без неё.
  static Future<void> run(
    ReportingApp app,
    FutureOr<void> Function() appRunner,
  ) async {
    if (!kReleaseMode) {
      await appRunner();
      return;
    }
    await SentryFlutter.init((o) {
      o.dsn = dsnFor(AppConfig.baseUrl);
      o.environment = const String.fromEnvironment(
        'SENTRY_ENVIRONMENT',
        defaultValue: 'prod',
      );
      o.sendDefaultPii = false;
      o.attachStacktrace = true;
      o.enablePrintBreadcrumbs = false;
      // Сессии (release health) Bugsink не разбирает, а ТСД без связи копил бы их на каждом
      // старте и сворачивании приложения.
      o.enableAutoSessionTracking = false;
    }, appRunner: appRunner);
    await Sentry.configureScope((s) => s.setTag('app', app.name));
  }

  /// Пользователь событий — по состоянию входа: id и роль, без имени и логина.
  static void bindAuth(AuthCubit auth) {
    void apply(AuthState s) => Sentry.configureScope(
      (scope) => scope.setUser(switch (s) {
        AuthAuthenticated(:final profile) => SentryUser(
          id: profile.userId,
          data: {'role': profile.role},
        ),
        _ => null,
      }),
    );
    apply(auth.state);
    auth.stream.listen(apply);
  }
}

/// Исключения, которые ловит `talker`, — в Bugsink (ADHOC-47).
///
/// Что пересылается: `talker.handle` (ошибки и исключения) и записи уровня error с исключением
/// внутри — так `talker` получает ошибки bloc. Что нет: записи без исключения (сбой принтера,
/// сетевые ошибки логгера dio) и `DioException` — связь и отказы сервера приложение разбирает
/// само, и на складе без связи они шли бы потоком. Без инициализации SDK (отладка, тесты)
/// отправка ничего не делает.
class ErrorReportingObserver extends TalkerObserver {
  const ErrorReportingObserver();

  @override
  void onError(TalkerError err) => _capture(err.error, err.stackTrace);

  @override
  void onException(TalkerException err) =>
      _capture(err.exception, err.stackTrace);

  @override
  void onLog(TalkerData log) {
    final level = log.logLevel;
    if (level != LogLevel.error && level != LogLevel.critical) return;
    _capture(log.exception ?? log.error, log.stackTrace);
  }

  void _capture(Object? error, StackTrace? stack) {
    if (!shouldReport(error)) return;
    unawaited(Sentry.captureException(error, stackTrace: stack));
  }

  /// Пересылать ли ошибку: только исключение, и не сетевое.
  @visibleForTesting
  static bool shouldReport(Object? error) =>
      error != null && error is! DioException;
}
