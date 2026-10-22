import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/sent_sessions.dart';

/// Отправка сеанса перемещения и его черновик (P6-04).
///
/// Зачем абстракция: cubit не знает ни про очередь, ни про базу черновиков — только «отправить»
/// и «сохранить незавершённое». Реализация — `MovementRepositoryImpl` в `data`.
abstract interface class MovementRepository {
  /// Поставить сеанс в очередь одной операцией `movement_submit` и попробовать отправить.
  ///
  /// [session] — слепок сеанса (как черновик): по нему отклонённый документ возвращается
  /// в черновик (ADHOC-41).
  ///
  /// `result`: `Right` — сервер провёл. `Left(RejectedFailure)` — отказ по существу, операция
  /// [operationId] ждёт разбора. Любой другой `Left` — связи нет, сеанс в очереди и уйдёт сам.
  Future<({String operationId, Either<Failure, void> result})> submit(
    Map<String, dynamic> payload, {
    required Map<String, dynamic> session,
  });

  /// Вернуть отклонённый сеанс [operationId] в черновик для правки (ADHOC-41, долг 26).
  ///
  /// Сеанс получает новый идентификатор документа и причину отказа, операция уходит из
  /// очереди. Черновик уже есть — [ReopenOutcome.draftBusy], слепка нет — [ReopenOutcome.lost].
  Future<ReopenOutcome> reopenRejected(String operationId);

  /// Незавершённый сеанс; `null` — его нет.
  Future<Map<String, dynamic>?> loadDraft();

  /// Сохранить незавершённый сеанс (перезаписывает предыдущий).
  Future<void> saveDraft(Map<String, dynamic> draft);

  /// Стереть черновик — сеанс завершён.
  Future<void> clearDraft();
}
