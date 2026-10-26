import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Должность глазами портала (ADHOC-50).
class PortalPosition {
  const PortalPosition({
    required this.id,
    required this.name,
    required this.rights,
    required this.isSystem,
    required this.users,
  });

  factory PortalPosition.fromJson(Map<String, dynamic> j) => PortalPosition(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    rights: [for (final r in j['rights'] as List? ?? const []) r as String],
    isSystem: j['is_system'] as bool? ?? false,
    users: (j['users'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;

  /// Действующие права; у системной — все.
  final List<String> rights;

  /// «Администратор»: все права, не меняется и не удаляется.
  final bool isSystem;

  /// Пользователей на должности, вместе с заблокированными.
  final int users;

  /// Удалить можно не системную и без пользователей.
  bool get canDelete => !isSystem && users == 0;
}

/// Пользователь глазами портала (ADHOC-50). Секрета бейджа и пароля портал не видит: у бейджа
/// — только логин (первые 8 цифр).
class PortalUser {
  const PortalUser({
    required this.id,
    required this.fullName,
    required this.positionId,
    required this.positionName,
    required this.login,
    required this.username,
    required this.isActive,
  });

  factory PortalUser.fromJson(Map<String, dynamic> j) => PortalUser(
    id: j['id'] as String,
    fullName: j['full_name'] as String? ?? '',
    positionId: j['position_id'] as String? ?? '',
    positionName: j['position_name'] as String? ?? '',
    login: j['login'] as String? ?? '',
    username: j['username'] as String? ?? '',
    isActive: j['is_active'] as bool? ?? true,
  );

  final String id;
  final String fullName;
  final String positionId;
  final String positionName;

  /// Первые 8 цифр бейджа; пусто — вход по логину и паролю.
  final String login;
  final String username;
  final bool isActive;

  /// Входит по бейджу.
  bool get byBadge => login.isNotEmpty;
}

/// Новый пользователь: ровно один вход — [badge] или [username] с [password].
typedef UserDraft = ({
  String fullName,
  String positionId,
  String? badge,
  String? username,
  String? password,
});

/// Пользователи и должности в портале (ADHOC-50); право «пользователи и должности».
///
/// Отказы по существу (занятый бейдж, последний администратор, должность с людьми) сервер
/// объясняет текстом в поле `error` — он приезжает в `ServerFailure.message`.
@lazySingleton
class UsersRepository {
  UsersRepository(this._dio);

  final Dio _dio;

  /// Должности: системная первой.
  Future<Either<Failure, List<PortalPosition>>> positions() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.positions);
    return [
      for (final e in resp.data ?? const [])
        PortalPosition.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести должность.
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
  Future<Either<Failure, void>> deletePosition(String id) =>
      _call(() => _dio.delete<void>(ApiConst.positionById(id)));

  /// Все пользователи, активные сверху.
  Future<Either<Failure, List<PortalUser>>> users() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.users);
    return [
      for (final e in resp.data ?? const [])
        PortalUser.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести пользователя.
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

  /// Изменить пользователя; `null` — поле не меняется.
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
