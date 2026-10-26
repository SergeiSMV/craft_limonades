import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../auth/token_storage.dart';
import '../config/app_config.dart';
import '../monitoring/error_reporting.dart';
import 'auth_interceptor.dart';

/// injectable-модуль: провайдит внешние объекты (Talker, Dio), которые нельзя пометить аннотацией.
@module
abstract class NetworkModule {
  /// Единый Talker — логгер приложения. В него пишут dio- и bloc-логгеры и его же
  /// показывает экран логов на устройстве (talker_flutter). Исключения из него уходят в
  /// Bugsink (ADHOC-47).
  @lazySingleton
  Talker get talker =>
      TalkerFlutter.init(observer: const ErrorReportingObserver());

  /// Настройки логгера dio.
  ///
  /// Что: в релизе тела ответов в лог НЕ пишутся, в отладочной сборке пишутся.
  ///
  /// Зачем — две причины, обе измерены на живом DT50S (P2-01).
  ///
  /// 1. **Скорость.** Печать одного ответа справочника ячеек (200 записей) занимала ~5 секунд
  ///    и давала 1822 строки в системном логе, при том что сам ответ приходил за 57 мс. Полная
  ///    загрузка справочника растягивалась до ~18 секунд, и кладовщик ждал её после каждой
  ///    завершённой ячейки.
  /// 2. **Секреты.** В лог целиком попадал ответ `/auth/login` — access- и refresh-токены
  ///    открытым текстом. Кто читает системный лог, тот получает и сессию.
  ///
  /// Диагностике это почти не мешает: адреса, коды ответов, тела запросов и сообщения об
  /// ошибках остаются, а разбор боевых сбоев по ним и идёт.
  static final _dioLoggerSettings = TalkerDioLoggerSettings(
    printResponseData: kDebugMode,
  );

  /// Таймауты запросов. Явные значения вместо «без таймаута»: на складе сеть
  /// нестабильна — запрос не должен висеть вечно, но и не рваться мгновенно.
  static const _connectTimeout = Duration(seconds: 10);
  static const _receiveTimeout = Duration(seconds: 15);

  /// «Голый» Dio для refresh и повтора запроса — без AuthInterceptor, чтобы не зациклиться.
  @Named('tokenDio')
  @lazySingleton
  Dio tokenDio() => Dio(
    BaseOptions(
      baseUrl: AppConfig.baseUrl,
      connectTimeout: _connectTimeout,
      receiveTimeout: _receiveTimeout,
    ),
  );

  /// Основной Dio: базовый URL + JWT-интерсептор + talker-логгер запросов/ответов.
  @lazySingleton
  Dio dio(
    TokenStorage storage,
    Talker talker,
    @Named('tokenDio') Dio tokenDio,
  ) {
    final dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.baseUrl,
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
      ),
    );
    dio.interceptors.add(AuthInterceptor(storage, tokenDio));
    dio.interceptors.add(
      TalkerDioLogger(talker: talker, settings: _dioLoggerSettings),
    );
    return dio;
  }
}
