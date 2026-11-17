import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'stocktake_models.dart';

/// Пересчёт на ТСД (P10-04): ячейки, взятие, начало подсчёта, отправка факта, черновики, а
/// старшему смены - заведение и закрытие.
///
/// Взять ячейку, отказаться и начать подсчёт - только со связью: кто держит ячейку и что в ней
/// ожидалось, знает сервер. Факт ячейки уходит операцией очереди и работает без связи.
abstract interface class StocktakeRepository {
  /// Пересчёт с ходом выполнения.
  Future<Either<Failure, StocktakeInfo>> stocktake(String id);

  /// Ячейки, которые работник может считать: свободные и свои.
  Future<Either<Failure, List<StocktakeCell>>> cells(String stocktakeId);

  /// Взять ячейку.
  Future<Either<Failure, void>> take(String cellId);

  /// Отказаться от ячейки; начатый подсчёт отбрасывается вместе с черновиком.
  Future<Either<Failure, void>> release(String cellId);

  /// Скан ячейки на месте: снимок и позиции для слепого счёта. Повтор снимок не трогает.
  Future<Either<Failure, StocktakeCellView>> start(String cellId);

  /// Поставить факт ячейки в очередь операцией `stocktake_cell_submit` и попробовать
  /// отправить. `Right` - сервер провёл; `Left(RejectedFailure)` - отказ по существу; любой
  /// другой `Left` - связи нет, факт в очереди и уйдёт сам. Черновик снимается в любом случае:
  /// работа либо на сервере, либо в очереди, либо ячейку считают заново.
  Future<Either<Failure, void>> submit(
    String cellId,
    Map<String, dynamic> payload,
  );

  /// Черновик подсчёта ячейки; `null` - нет.
  Future<Map<String, dynamic>?> loadDraft(String cellId);

  /// Сохранить черновик подсчёта ячейки (перезаписывает предыдущий).
  Future<void> saveDraft(String cellId, Map<String, dynamic> draft);

  /// Черновики подсчёта ячеек пересчёта [stocktakeId] - продолжить без связи.
  Future<List<Map<String, dynamic>>> drafts(String stocktakeId);

  /// Завести пересчёт по области (старший смены).
  Future<Either<Failure, StocktakeCreated>> create({
    required String warehouseId,
    required String scopeKind,
    List<String> objectIds,
  });

  /// Закрыть пересчёт; [force] - с неподсчитанными ячейками.
  Future<Either<Failure, void>> close(String id, {required bool force});
}
