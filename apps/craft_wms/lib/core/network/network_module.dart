import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../auth/token_storage.dart';
import '../config/app_config.dart';
import 'auth_interceptor.dart';

/// injectable-модуль: провайдит внешние объекты (Talker, Dio), которые нельзя пометить аннотацией.
@module
abstract class NetworkModule {
  /// Единый Talker — логгер приложения. В него пишут dio- и bloc-логгеры и его же
  /// показывает экран логов на устройстве (talker_flutter).
  @lazySingleton
  Talker get talker => TalkerFlutter.init();

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
    dio.interceptors.add(TalkerDioLogger(talker: talker));
    return dio;
  }
}
