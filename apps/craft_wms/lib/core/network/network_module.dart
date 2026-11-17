import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../auth/token_storage.dart';
import '../config/app_config.dart';
import '../monitoring/error_reporting.dart';
import '../sync/data_versions.dart';
import 'auth_interceptor.dart';
import 'data_versions_interceptor.dart';

/// injectable-модуль: провайдит внешние объекты (Talker, Dio), которые нельзя пометить аннотацией.
@module
abstract class NetworkModule {
  /// Единый Talker - логгер приложения. В него пишут dio- и bloc-логгеры и его же
  /// показывает экран логов на устройстве (talker_flutter). Исключения из него уходят в
  /// Bugsink (ADHOC-47).
  @lazySingleton
  Talker get talker =>
      TalkerFlutter.init(observer: const ErrorReportingObserver());

  /// Настройки логгера dio.
  ///
  /// Что: в релизе тела ответов в лог НЕ пишутся, в отладочной сборке пишутся.
  ///
  /// Зачем - две причины, обе измерены на живом DT50S (P2-01).
  ///
  /// 1. **Скорость.** Печать одного ответа справочника ячеек (200 записей) занимала ~5 секунд
  ///    и давала 1822 строки в системном логе, при том что сам ответ приходил за 57 мс. Полная
  ///    загрузка справочника растягивалась до ~18 секунд, и кладовщик ждал её после каждой
  ///    завершённой ячейки.
  /// 2. **Секреты.** В лог целиком попадал ответ `/auth/login` - access- и refresh-токены
  ///    открытым текстом. Кто читает системный лог, тот получает и сессию.
  ///
  /// Диагностике это почти не мешает: адреса, коды ответов, тела запросов и сообщения об
  /// ошибках остаются, а разбор боевых сбоев по ним и идёт.
  static final _dioLoggerSettings = TalkerDioLoggerSettings(
    printResponseData: kDebugMode,
  );

  /// Таймауты запросов. Явные значения вместо «без таймаута»: на складе сеть
  /// нестабильна - запрос не должен висеть вечно, но и не рваться мгновенно.
  static const _connectTimeout = Duration(seconds: 10);
  static const _receiveTimeout = Duration(seconds: 15);

  /// «Голый» Dio для refresh и повтора запроса - без AuthInterceptor, чтобы не зациклиться.
  ///
  /// Версии данных (ADHOC-60) читаются и здесь: повтор запроса после обновления токена идёт
  /// через этот Dio, и его ответ перехватчики основного Dio не видят.
  @Named('tokenDio')
  @lazySingleton
  Dio tokenDio(DataVersions versions) =>
      Dio(
          BaseOptions(
            baseUrl: AppConfig.baseUrl,
            connectTimeout: _connectTimeout,
            receiveTimeout: _receiveTimeout,
          ),
        )
        ..interceptors.add(DataVersionsInterceptor(versions));

  /// Основной Dio: базовый URL + JWT-интерсептор + talker-логгер запросов/ответов.
  @lazySingleton
  Dio dio(
    TokenStorage storage,
    Talker talker,
    DataVersions versions,
    @Named('tokenDio') Dio tokenDio,
  ) {
    final dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.baseUrl,
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
      ),
    );
    // Версии данных - первыми: ответ с ошибкой AuthInterceptor может подменить повтором, и
    // заголовок исходного ответа иначе не дошёл бы до них (ADHOC-60).
    dio.interceptors.add(DataVersionsInterceptor(versions));
    dio.interceptors.add(AuthInterceptor(storage, tokenDio));
    dio.interceptors.add(
      TalkerDioLogger(talker: talker, settings: _dioLoggerSettings),
    );
    return dio;
  }
}
