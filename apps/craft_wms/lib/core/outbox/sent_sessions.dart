import 'package:injectable/injectable.dart';

import '../database/app_database.dart';
import '../database/draft_slot.dart';

/// Чем кончилась попытка вернуть отклонённый сеанс в черновик (ADHOC-41).
enum ReopenOutcome {
  /// Сеанс снова черновик, отклонённая операция убрана из очереди.
  reopened,

  /// В разделе уже идёт другой сеанс - его черновик не затираем.
  draftBusy,

  /// Слепка сеанса нет (операция поставлена до ADHOC-41) - восстанавливать нечего.
  lost,
}

/// Слепки сеансов, отправленных документом, - до подтверждения сервером (ADHOC-41, долг 26).
///
/// Что: копия черновика сеанса (перемещение, размещение) под идентификатором операции очереди.
/// Зачем: на «Завершить» черновик стирается, а в теле операции - одни идентификаторы, из
///        которых сеанс не собрать: названия товаров, адреса, коды коробов знает только
///        черновик. Отклонённый сервером документ без копии можно было лишь повторить или
///        отбросить, а исправить - только собрав работу заново.
/// Как: та же таблица черновиков, ключ `sent:<operation_id>`. Слепок убирает очередь, когда
///      операцию подтвердил сервер или её отбросили ([OutboxRepository]); отказ его оставляет.
@lazySingleton
class SentSessionStore {
  SentSessionStore(this._db);

  final AppDatabase _db;

  /// Ключ строки слепка - его же чистит очередь.
  static String keyFor(String operationId) => 'sent:$operationId';

  DraftSlot _slot(String operationId) => _SentSlot(_db, keyFor(operationId));

  /// Сохранить слепок сеанса, ушедшего операцией [operationId].
  Future<void> save(String operationId, Map<String, dynamic> session) =>
      _slot(operationId).save(session);

  /// Слепок сеанса; `null` - его нет.
  Future<Map<String, dynamic>?> load(String operationId) =>
      _slot(operationId).load();
}

/// Строка таблицы черновиков под ключом слепка - правила записи и разбора общие с черновиками.
class _SentSlot extends DraftSlot {
  _SentSlot(super.db, super.key);
}
