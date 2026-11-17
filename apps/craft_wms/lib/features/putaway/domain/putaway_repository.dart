import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/sent_sessions.dart';

/// Отправка сеанса размещения и работа с его заданием (P5-03).
///
/// Зачем абстракция: cubit размещения и экран очереди синхронизации не знают про очередь
/// операций, снимок заданий и слепки отправленных сеансов (`dev.md §2`, ADHOC-71).
/// Реализация - `PutawayRepositoryImpl` в `data`.
abstract interface class PutawayRepository {
  /// Отдать задание в пул - его незавершённый сеанс кладовщик отбросил. Только со связью;
  /// удалось - снимок текущих заданий обновляется.
  Future<Either<Failure, void>> releaseTask(String taskId);

  /// Поставить сеанс в очередь одной операцией `putaway_submit` и попробовать отправить.
  ///
  /// [session] - слепок сеанса (как черновик): по нему отклонённый документ возвращается
  /// в черновик (ADHOC-41). [boxes] и [loose] - что сеанс разместил: без связи этим
  /// отмечается снимок заданий.
  ///
  /// `result`: `Right` - сервер провёл. `Left(RejectedFailure)` - отказ по существу: операция
  /// [operationId] ждёт разбора. Любой другой `Left` - связи нет, сеанс в очереди; работа уже
  /// не потеряется.
  Future<({String operationId, Either<Failure, void> result})> submit({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> session,
    required String taskId,
    required Set<String> boxes,
    required Map<(String, String), double> loose,
  });

  /// Вернуть отклонённый сеанс [operationId] в черновик для правки (ADHOC-41, долг 26).
  /// Второе значение - номер задания, чтобы сказать кладовщику, куда идти. Черновик уже
  /// есть - [ReopenOutcome.draftBusy], слепка нет - [ReopenOutcome.lost].
  Future<(ReopenOutcome, int)> reopenRejected(String operationId);
}
