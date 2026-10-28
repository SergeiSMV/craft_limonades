import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Перепривязка ШК маркируемого товара с пересортом марок ЧЗ (ADHOC-53).
///
/// Только онлайн: сервер в одной транзакции переводит ШК, марки и их остаток на другой товар и
/// заводит пересорт в «Проблемах склада» — на терминале этого не повторить, и в очередь
/// перепривязка не ставится.
abstract interface class CzRegradeRepository {
  /// Сколько марок ЧЗ с этим ШК лежит на складе — перед отвязкой ШК маркируемого товара.
  Future<Either<Failure, int>> marksInStock(String barcode);

  /// Перепривязать ШК к товару [goodId]; результат — сколько марок перешло.
  Future<Either<Failure, int>> regrade({
    required String barcode,
    required String goodId,
  });
}
