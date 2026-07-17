import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../error/failure.dart';
import 'profile.dart';
import 'token_storage.dart';

/// Репозиторий аутентификации: ходит на `/auth/*` и возвращает `Either<Failure, T>`.
/// Слой data чистой архитектуры — изолирует сеть от домена/UI.
@lazySingleton
class AuthRepository {
  AuthRepository(this._dio, this._storage);

  final Dio _dio;
  final TokenStorage _storage;

  /// Вход по бейджу: `/auth/login` → сохраняем пару токенов → `/auth/me` → профиль.
  Future<Either<Failure, Profile>> login(String badge) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'badge': badge},
      );
      final data = resp.data!;
      await _storage.save(
        access: data['access'] as String,
        refresh: data['refresh'] as String,
      );
      return me();
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Профиль текущего пользователя (защищённый `/auth/me`; access подставит интерсептор).
  Future<Either<Failure, Profile>> me() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>('/auth/me');
      return Right(Profile.fromJson(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Есть ли сохранённая сессия (токен в secure storage).
  /// Нужно для тихого восстановления при старте: без токенов сразу уходим на вход,
  /// не дёргая сеть.
  Future<bool> hasSession() async => (await _storage.readAccess()) != null;

  /// Выход — просто чистим токены.
  Future<void> logout() => _storage.clear();

  /// Маппинг ошибок dio в доменные Failure (что показать/как реагировать — решает bloc).
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 400) {
      return const Failure.auth('Неверный бейдж');
    }
    if (code != null) {
      return Failure.server(code);
    }
    return const Failure.network();
  }
}
