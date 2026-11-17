import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/users/users_repository.dart';

/// Пользователи и должности в портале (ADHOC-50); право «пользователи и должности».
///
/// Отказы по существу (занятый бейдж, последний администратор, должность с людьми) сервер
/// объясняет текстом в поле `error` - он приезжает в `ServerFailure.message`.
@LazySingleton(as: UsersRepository)
class UsersRepositoryImpl implements UsersRepository {
  UsersRepositoryImpl(this._dio);

  final Dio _dio;

  /// Должности: системная первой.
  @override
  Future<Either<Failure, List<PortalPosition>>> positions() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.positions);
    return [
      for (final e in resp.data ?? const [])
        PortalPosition.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести должность.
  @override
  Future<Either<Failure, void>> createPosition(
    String name,
    List<String> rights,
  ) => _call(
    () => _dio.post<void>(
      ApiConst.positions,
      data: {'name': name, 'rights': rights},
    ),
  );

  /// Изменить название и права должности.
  @override
  Future<Either<Failure, void>> updatePosition(
    String id,
    String name,
    List<String> rights,
  ) => _call(
    () => _dio.patch<void>(
      ApiConst.positionById(id),
      data: {'name': name, 'rights': rights},
    ),
  );

  /// Удалить должность без пользователей.
  @override
  Future<Either<Failure, void>> deletePosition(String id) =>
      _call(() => _dio.delete<void>(ApiConst.positionById(id)));

  /// Все пользователи, активные сверху.
  @override
  Future<Either<Failure, List<PortalUser>>> users() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.users);
    return [
      for (final e in resp.data ?? const [])
        PortalUser.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести пользователя.
  @override
  Future<Either<Failure, void>> createUser(UserDraft d) => _call(
    () => _dio.post<void>(
      ApiConst.users,
      data: {
        'full_name': d.fullName,
        'position_id': d.positionId,
        'badge': ?d.badge,
        'username': ?d.username,
        'password': ?d.password,
      },
    ),
  );

  /// Изменить пользователя; `null` - поле не меняется.
  @override
  Future<Either<Failure, void>> updateUser(
    String id, {
    String? fullName,
    String? positionId,
    bool? isActive,
    String? badge,
    String? password,
  }) => _call(
    () => _dio.patch<void>(
      ApiConst.userById(id),
      data: {
        'full_name': ?fullName,
        'position_id': ?positionId,
        'is_active': ?isActive,
        'badge': ?badge,
        'password': ?password,
      },
    ),
  );

  Future<Either<Failure, T>> _call<T>(Future<T> Function() run) async {
    try {
      return Right(await run());
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      final data = e.response?.data;
      final message = data is Map ? data['error'] as String? : null;
      return Left(Failure.server(code, message));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
