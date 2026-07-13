import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';

import '../error/failure.dart';
import 'auth_repository.dart';
import 'profile.dart';

part 'auth_cubit.freezed.dart';

/// Состояние аутентификации приложения (sealed-union freezed).
/// Именно оно гейтит навигацию: см. app.dart (BlocListener) и AuthGuard.
@freezed
sealed class AuthState with _$AuthState {
  /// Стартовое состояние до первой попытки входа.
  const factory AuthState.unknown() = AuthUnknown;

  /// Идёт вход (показываем прогресс, блокируем кнопку).
  const factory AuthState.authenticating() = AuthAuthenticating;

  /// Вошли — держим профиль текущего пользователя.
  const factory AuthState.authenticated(Profile profile) = AuthAuthenticated;

  /// Не вошли; failure — причина последней неудачи (для показа ошибки).
  const factory AuthState.unauthenticated([Failure? failure]) = AuthUnauthenticated;
}

/// Cubit аутентификации. Синглтон на всё приложение (одно состояние входа).
@lazySingleton
class AuthCubit extends Cubit<AuthState> {
  AuthCubit(this._repo) : super(const AuthState.unknown());

  final AuthRepository _repo;

  /// Вход по бейджу: делегируем репозиторию и превращаем Either в состояние.
  Future<void> login(String badge) async {
    emit(const AuthState.authenticating());
    final result = await _repo.login(badge);
    result.fold(
      (failure) => emit(AuthState.unauthenticated(failure)),
      (profile) => emit(AuthState.authenticated(profile)),
    );
  }

  /// Выход.
  Future<void> logout() async {
    await _repo.logout();
    emit(const AuthState.unauthenticated());
  }
}
