import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Отправка приёмки на сервер (P4-09).
///
/// Зачем абстракция: cubit приёмки не знает про очередь операций и движок синхронизации -
/// только «отправить» (`dev.md §2`, ADHOC-71). Реализация - `ReceiptRepositoryImpl` в `data`.
abstract interface class ReceiptRepository {
  /// Поставить приёмку в очередь одной операцией `receipt_submit` и попробовать отправить.
  ///
  /// `Right` - сервер оприходовал. `Left(RejectedFailure)` - отказ по существу: операция лежит
  /// в очереди отклонённой и ждёт разбора. Любой другой `Left` - связи нет, операция ждёт
  /// отправки; работа кладовщика при этом уже не потеряется.
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload);
}
