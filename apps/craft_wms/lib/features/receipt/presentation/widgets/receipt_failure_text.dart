import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../bloc/receipt_cubit.dart';

/// Текст ошибки для снекбара в потоке приёмки.
String receiptFailureText(Failure f) => switch (f) {
  UnknownFailure(message: kNoDefaultCell) => t.receipt.noDefaultCell,
  ServerFailure(:final message, :final statusCode) =>
    message ?? 'HTTP $statusCode',
  NetworkFailure() => t.receipt.errorNetwork,
  AuthFailure() => t.receipt.errorAuth,
  // Отказ по существу: причину прислал сервер, и она конкретнее любой нашей формулировки.
  RejectedFailure(:final reason) => reason,
  _ => t.receipt.errorUnknown,
};
