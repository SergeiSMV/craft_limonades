import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Отправка сеанса перемещения и его черновик (P6-04).
///
/// Зачем абстракция: cubit не знает ни про очередь, ни про базу черновиков — только «отправить»
/// и «сохранить незавершённое». Реализация — `MovementRepositoryImpl` в `data`.
abstract interface class MovementRepository {
  /// Поставить сеанс в очередь одной операцией `movement_submit` и попробовать отправить.
  ///
  /// `Right` — сервер провёл. `Left(RejectedFailure)` — отказ по существу, операция ждёт
  /// разбора. Любой другой `Left` — связи нет, сеанс в очереди и уйдёт сам.
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload);

  /// Незавершённый сеанс; `null` — его нет.
  Future<Map<String, dynamic>?> loadDraft();

  /// Сохранить незавершённый сеанс (перезаписывает предыдущий).
  Future<void> saveDraft(Map<String, dynamic> draft);

  /// Стереть черновик — сеанс завершён.
  Future<void> clearDraft();
}
