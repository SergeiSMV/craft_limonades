import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Отправка сеанса отгрузки возврата поставщику (ADHOC-31).
///
/// `Right` - сервер провёл, задание выполнено. `Left(RejectedFailure)` - отказ по существу:
/// операция ждёт разбора в «Несинхронизированном». Любой другой `Left` - связи нет, сеанс
/// в очереди и уйдёт сам.
abstract interface class SupplierReturnRepository {
  Future<Either<Failure, void>> submit({
    required Map<String, dynamic> payload,
    required String taskId,
    required Set<String> problemIds,
  });
}
