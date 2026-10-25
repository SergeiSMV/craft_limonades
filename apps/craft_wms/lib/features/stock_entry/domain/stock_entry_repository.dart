import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Сессия ввода остатков на сервере: старт, checkpoint ячейки, финал (P-FastStart, ADHOC-46).
///
/// Зачем абстракция: cubit не знает ни про HTTP, ни про очередь операций. Реализация —
/// `StockEntryRepositoryImpl` в `data`.
abstract interface class StockEntryRepository {
  /// Открыть сессию ввода для склада; возвращает её id.
  Future<Either<Failure, String>> startSession(String warehouseId);

  /// Зафиксировать ячейку в сессии телом [body] (`entryCellBody`). Отказ строк сервер
  /// присылает текстом со списком плохих строк — он в `ServerFailure.message`.
  Future<Either<Failure, void>> checkpoint({
    required String sessionId,
    required Map<String, dynamic> body,
  });

  /// Финал сессии: перенос в остатки и закрытие. Возвращает число записанных граней.
  Future<Either<Failure, int>> finalize(String sessionId);

  /// Отправить очередь операций и сказать, опустела ли она.
  ///
  /// Финал сверяет GTIN каждой марки с ШК её товара, а привязка ШК из марки уходит операцией
  /// очереди: проход с марками завершается только после того, как привязки дошли.
  Future<bool> drainQueue();
}
