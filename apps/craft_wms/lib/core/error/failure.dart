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
  const factory Failure.server(int statusCode, [String? message]) =
      ServerFailure;

  /// Сервер отказал по существу — повтор не поможет, нужен разбор человеком.
  ///
  /// Отдельный вариант появился с батч-приёмом операций (P2-05): там отказ приезжает ВНУТРИ
  /// успешного 200-го ответа, полем `status: "rejected"`, а не кодом HTTP. Прежде такой отказ
  /// пришлось бы изображать через `Failure.server(409, …)` — то есть выдумывать код, которого
  /// в ответе не было, и делать правило повтора зависимым от этой выдумки.
  const factory Failure.rejected(String reason) = RejectedFailure;

  /// Всё остальное.
  const factory Failure.unknown([String? message]) = UnknownFailure;
}
