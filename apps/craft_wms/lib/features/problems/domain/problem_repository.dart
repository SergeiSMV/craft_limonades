import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../core/problems/problem_reasons.dart';
import '../../../core/warehouse/internal_warehouses.dart';

/// Отправка проблемы склада и склады, куда её можно пометить (P6-07-2).
///
/// Зачем абстракция: cubit не знает ни про очередь, ни про справочник складов в базе.
/// Реализация - `ProblemRepositoryImpl` в `data`.
abstract interface class ProblemRepository {
  /// Поставить проблему в очередь операцией `problem_submit` и попробовать отправить.
  ///
  /// `Right` - сервер провёл. `Left(RejectedFailure)` - отказ по существу, операция ждёт
  /// разбора. Любой другой `Left` - связи нет, проблема в очереди и уйдёт сама.
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload);

  /// Склады, которыми можно пометить товар, - все, кроме «Основного» и скрытых в портале.
  Future<List<InternalWarehouse>> markWarehouses();

  /// Причины, которые кладовщик выбирает при пометке (ADHOC-55): активные из справочника,
  /// кроме тех, что ставит только программа.
  Future<List<ProblemReason>> markReasons();
}
