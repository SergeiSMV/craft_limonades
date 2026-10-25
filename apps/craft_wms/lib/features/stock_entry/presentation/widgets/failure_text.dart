import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../bloc/stock_entry_cubit.dart';

/// Текст ошибки для снекбара в потоке ввода остатков — общий для страницы (BlocListener)
/// и инлайн-отвязки ШК («неверный товар»).
String stockEntryFailureText(Failure f) => switch (f) {
  ServerFailure(:final message, :final statusCode) =>
    message ?? 'HTTP $statusCode',
  NetworkFailure() => t.stockEntry.errorNetwork,
  AuthFailure() => t.stockEntry.errorAuth,
  // Отказ по существу из батча операций (P2-05): причину прислал сервер, и она конкретнее
  // любой нашей формулировки. Без этой ветки она провалилась бы в «неизвестная ошибка» —
  // ровно та потеря причины, которую чинили в P2-06.
  RejectedFailure(:final reason) => reason,
  UnknownFailure(message: kQueuePending) => t.stockEntry.queuePending,
  _ => t.stockEntry.errorUnknown,
};
