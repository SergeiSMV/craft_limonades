import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/dio_failure.dart';
import '../../core/error/failure.dart';
import '../domain/demo/demo_repository.dart';

/// Демо-сервер поверх API ADHOC-67.
///
/// Состояние читается «голым» Dio (`tokenDio`): его спрашивают при старте портала, до
/// хранилища сессии, — а от ответа зависят ключи этой сессии (`SecureTokenStorage`).
@LazySingleton(as: DemoRepository)
class DemoRepositoryImpl implements DemoRepository {
  DemoRepositoryImpl(this._dio, @Named('tokenDio') this._plainDio);

  final Dio _dio;
  final Dio _plainDio;

  /// Предел ожидания ответа о режиме: портал не должен висеть на старте.
  static const _statusTimeout = Duration(seconds: 5);

  @override
  Future<bool> isDemoServer() async {
    try {
      final resp = await _plainDio.get<Map<String, dynamic>>(
        ApiConst.demoStatus,
        options: Options(receiveTimeout: _statusTimeout),
      );
      return resp.data?['enabled'] == true;
    } catch (_) {
      // 404 рабочего сервера, нет связи — рабочий режим.
      return false;
    }
  }

  @override
  Future<Either<Failure, void>> reset() async {
    try {
      await _dio.post<void>(ApiConst.demoReset);
      return const Right(null);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
