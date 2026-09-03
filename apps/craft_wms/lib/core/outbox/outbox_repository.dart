import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import 'outbox_operation.dart';

/// Очередь исходящих операций устройства (Outbox, P2-03).
///
/// Что: единственная точка, через которую операция попадает в локальную очередь и меняет
/// в ней статус.
/// Зачем: пока операция живёт только в памяти вызывающего кода, обрыв связи и перезапуск
/// приложения неотличимы от «операции не было». Строка в базе делает факт операции
/// независимым от того, дошёл ли запрос и жив ли процесс.
/// Как: [enqueue] пишет строку со статусом `pending` и выдаёт `operation_id`; отправщик
/// (P2-04) забирает [pending] в порядке [OutboxOperation.seq] и двигает статусы
/// через [markSending] / [markSent] / [markFailed] / [markRejected].
///
/// ⚠ Отправки здесь нет намеренно. P2-03 отвечает за то, что операция **не теряется**;
/// доставку, ретраи и backoff добавляет P2-04. Поэтому в этой версии строки, не ушедшие
/// с первой попытки, остаются в `pending` и просто ждут.
@lazySingleton
class OutboxRepository {
  OutboxRepository(this._db, this._uuid);

  final AppDatabase _db;
  final Uuid _uuid;

  /// Поставить операцию в очередь. Возвращает `operation_id` — ключ идемпотентности,
  /// по которому сервер отбросит повтор (P2-05).
  ///
  /// Идентификатор генерируется **здесь, а не на сервере**: смысл очереди в том, чтобы
  /// операция существовала до и независимо от сетевого вызова, а серверный идентификатор
  /// без сети получить неоткуда.
  ///
  /// **Точно такая же ожидающая операция не дублируется** (ADHOC-09): очередь — список дел,
  /// а одно и то же дело в нём дважды не нужно. Возвращается идентификатор уже стоящей
  /// операции, и вызывающий об этом даже не узнаёт.
  ///
  /// Дефект, из-за которого правило появилось: экран сообщал «не удалось привязать», хотя
  /// операция была принята и ждала связи. Кладовщик жал кнопку снова, каждое нажатие
  /// добавляло в очередь новую копию, и на устройстве нашлись четыре одинаковых привязки
  /// одного ШК. При появлении связи первая уходила, а остальные упирались в уникальность
  /// штрихкода на сервере и оседали отклонёнными.
  Future<String> enqueue({
    required OutboxKind kind,
    required Map<String, dynamic> payload,
  }) async {
    final body = jsonEncode(payload);
    final duplicate = await _pendingSameAs(kind: kind, payload: body);
    if (duplicate != null) return duplicate;

    final operationId = _uuid.v4();
    final now = DateTime.now();
    await _db
        .into(_db.outboxOperations)
        .insert(
          OutboxOperationsCompanion.insert(
            operationId: operationId,
            kind: kind.wire,
            payload: body,
            status: OutboxStatus.pending.wire,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return operationId;
  }

  /// Идентификатор ожидающей операции с тем же типом и телом, если такая уже есть.
  ///
  /// Сравнивается закодированное тело, а не разобранная карта: строка в базе лежит именно
  /// в этом виде, и `jsonEncode` от одного и того же источника даёт одинаковый результат.
  /// `sent` и `rejected` в сравнение не входят — своё дело они уже отслужили, и повторная
  /// постановка после них законна (например, кладовщик отвязал ШК и привязывает снова).
  Future<String?> _pendingSameAs({
    required OutboxKind kind,
    required String payload,
  }) async {
    final query = _db.select(_db.outboxOperations)
      ..where(
        (t) =>
            t.kind.equals(kind.wire) &
            t.payload.equals(payload) &
            t.status.isIn([
              OutboxStatus.pending.wire,
              OutboxStatus.sending.wire,
            ]),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.seq)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.operationId;
  }

  /// Операции, ожидающие отправки, в порядке постановки.
  ///
  /// `sending` сюда включён намеренно: этот статус означает «попытка шла, когда процесс
  /// умер», и судьба операции на сервере неизвестна. Оставить такую строку вне очереди —
  /// значит потерять операцию, которая, возможно, не дошла; повторить — безопасно, потому
  /// что дедуп по `operation_id` отбросит её, если она всё-таки дошла.
  Future<List<OutboxOperation>> pending({int limit = 100}) async {
    final query = _db.select(_db.outboxOperations)
      ..where(
        (t) => t.status.isIn([
          OutboxStatus.pending.wire,
          OutboxStatus.sending.wire,
        ]),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.seq)])
      ..limit(limit);
    final rows = await query.get();
    // Строки с неизвестным типом или статусом пропускаем: их писала более новая версия
    // приложения, и отправлять их вслепую нельзя. В базе они остаются — после обновления
    // разберутся сами.
    return rows.map(OutboxOperation.fromRow).nonNulls.toList();
  }

  /// Сколько операций ждёт отправки — для индикатора неотправленного (P2-07).
  Future<int> pendingCount() async {
    final count = _db.outboxOperations.seq.count();
    final query = _db.selectOnly(_db.outboxOperations)
      ..addColumns([count])
      ..where(
        _db.outboxOperations.status.isIn([
          OutboxStatus.pending.wire,
          OutboxStatus.sending.wire,
        ]),
      );
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Операция по её `operation_id` — `null`, если такой нет.
  Future<OutboxOperation?> byOperationId(String operationId) async {
    final query = _db.select(_db.outboxOperations)
      ..where((t) => t.operationId.equals(operationId));
    final row = await query.getSingleOrNull();
    return row == null ? null : OutboxOperation.fromRow(row);
  }

  /// Отметить начало отправки.
  Future<void> markSending(String operationId) =>
      _update(operationId, status: OutboxStatus.sending);

  /// Сервер принял операцию.
  Future<void> markSent(String operationId) =>
      _update(operationId, status: OutboxStatus.sent, clearError: true);

  /// Попытка не удалась — операция возвращается в очередь и будет повторена (P2-04).
  /// Счётчик попыток увеличивается: по нему P2-04 считает паузу backoff.
  Future<void> markFailed(String operationId, String error) => _update(
    operationId,
    status: OutboxStatus.pending,
    error: error,
    bumpAttempts: true,
  );

  /// Сервер отказал по существу — повтор не поможет, нужен разбор (P2-06).
  Future<void> markRejected(String operationId, String error) =>
      _update(operationId, status: OutboxStatus.rejected, error: error);

  /// Убрать успешно отправленные операции: очередь — это список дел, а не журнал.
  /// Историей занимается серверный журнал документов (P3-07).
  Future<int> purgeSent() => (_db.delete(
    _db.outboxOperations,
  )..where((t) => t.status.equals(OutboxStatus.sent.wire))).go();

  /// Общая правка строки: статус, ошибка, счётчик попыток и метка времени.
  Future<void> _update(
    String operationId, {
    required OutboxStatus status,
    String? error,
    bool clearError = false,
    bool bumpAttempts = false,
  }) async {
    final current = await byOperationId(operationId);
    // Строку уже удалили — правкой ничего не воскрешаем.
    if (current == null) return;
    final statement = _db.update(_db.outboxOperations)
      ..where((t) => t.operationId.equals(operationId));
    await statement.write(
      OutboxOperationsCompanion(
        status: Value(status.wire),
        attempts: bumpAttempts
            ? Value(current.attempts + 1)
            : const Value.absent(),
        lastError: clearError
            ? const Value(null)
            : (error == null ? const Value.absent() : Value(error)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
