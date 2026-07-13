import 'package:freezed_annotation/freezed_annotation.dart';

part 'failure.freezed.dart';

/// Типизированные ошибки домена (sealed-union freezed).
///
/// Зачем: ошибки — часть контракта. Репозитории возвращают `Either<Failure, T>`,
/// а bloc через `fold` превращает Failure в состояние ошибки — без try/catch в UI.
@freezed
sealed class Failure with _$Failure {
  /// Нет сети / таймаут / бэкенд недоступен.
  const factory Failure.network([String? message]) = NetworkFailure;

  /// Ошибка аутентификации (неверный бейдж, 401/400).
  const factory Failure.auth([String? message]) = AuthFailure;

  /// Сервер вернул ошибку (5xx и прочие с кодом).
  const factory Failure.server(int statusCode, [String? message]) = ServerFailure;

  /// Всё остальное.
  const factory Failure.unknown([String? message]) = UnknownFailure;
}
