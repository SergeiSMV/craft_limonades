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

  /// Тихое восстановление сессии при старте приложения (авто-рефреш).
  /// Что: если в secure storage есть токены — проверяем их через `/auth/me`.
  /// Зачем: кладовщик не должен пересканировать бейдж после перезапуска ТСД.
  /// Как: нет токенов → сразу на вход; есть → `me()` (интерсептор сам обновит
  ///      access по refresh при 401). Успех → authenticated; отказ (refresh протух —
  ///      интерсептор уже почистил хранилище; или нет сети) → unauthenticated.
  Future<void> restore() async {
    if (!await _repo.hasSession()) {
      emit(const AuthState.unauthenticated());
      return;
    }
    final result = await _repo.me();
    if (result.isRight) {
      emit(AuthState.authenticated(result.right));
      return;
    }
    // Сети нет — пробуем локальную сессию: без этого терминал, перезагруженный вне зоны
    // Wi-Fi, упирается в экран входа, и офлайн-кэш становится недостижим (P2-02).
    // Отказ сервера (протухший refresh) сюда не попадает: там ошибка не сетевая.
    if (result.left is NetworkFailure) {
      final offline = await _repo.offlineSession();
      if (offline != null) {
        emit(AuthState.authenticated(offline));
        return;
      }
    }
    emit(AuthState.unauthenticated(result.left));
  }

  /// Вход по бейджу: делегируем репозиторию и превращаем Either в состояние.
  /// Защита от повторного сабмита: экран входа шлёт submit и на автосабмите (16 цифр),
  /// и на Enter — без гарда это два `/auth/login`. Пока идёт вход — игнорируем повтор.
  Future<void> login(String badge) async {
    if (state is AuthAuthenticating) return;
    emit(const AuthState.authenticating());
    final result = await _repo.login(badge);
    result.fold(
      (failure) => emit(AuthState.unauthenticated(failure)),
      (profile) => emit(AuthState.authenticated(profile)),
    );
  }

  /// Вход по логину/паролю (веб-портал / смартфон-админ). Как [login], но по учётным данным.
  Future<void> loginWithPassword(String username, String password) async {
    if (state is AuthAuthenticating) return;
    emit(const AuthState.authenticating());
    final result = await _repo.loginWithPassword(username, password);
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
