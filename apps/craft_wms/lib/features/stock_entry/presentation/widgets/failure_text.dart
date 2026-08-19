import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';

/// Текст ошибки для снекбара в потоке ввода остатков — общий для страницы (BlocListener)
/// и инлайн-отвязки ШК («неверный товар»).
String stockEntryFailureText(Failure f) => switch (f) {
  ServerFailure(:final message, :final statusCode) => message ?? 'HTTP $statusCode',
  NetworkFailure() => t.stockEntry.errorNetwork,
  AuthFailure() => t.stockEntry.errorAuth,
  _ => t.stockEntry.errorUnknown,
};
