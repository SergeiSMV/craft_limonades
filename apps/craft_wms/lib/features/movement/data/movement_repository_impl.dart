import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/draft_slot.dart';
import '../../../core/error/failure.dart';
import '../../../core/load_unit/load_unit_id_generator.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/outbox/sent_sessions.dart';
import '../../../core/sync/sync_engine.dart';
import '../domain/movement_repository.dart';

/// Хранилище незавершённого сеанса перемещения (P6-04).
///
/// До «Завершить» сеанс существует только здесь: перенесённое не должно пропасть из учёта из-за
/// разряда батареи посередине. Отдельный класс — ради живой пометки на плитке главного меню.
@lazySingleton
class MovementDraftStore extends DraftSlot {
  MovementDraftStore(AppDatabase db) : super(db, 'movement');
}

/// Отправка сеанса перемещения тем же путём, что приёмка и размещение (P6-04).
///
/// Что: ставит сеанс в очередь одной операцией `movement_submit` и сразу пробует отправить.
/// Не дошёл сейчас — уйдёт сам при появлении связи. Снимок содержимого склада обновляет
/// подтверждение операции (`OutboxEffects`), а до него свою операцию поверх снимка
/// накладывает чтение содержимого — короб без связи уже «лежит» там, куда его перенесли.
@LazySingleton(as: MovementRepository)
class MovementRepositoryImpl implements MovementRepository {
  MovementRepositoryImpl(
    this._outbox,
    this._sync,
    this._drafts,
    this._sent,
    this._ids,
  );

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final MovementDraftStore _drafts;
  final SentSessionStore _sent;
  final LoadUnitIdGenerator _ids;

  @override
  Future<({String operationId, Either<Failure, void> result})> submit(
    Map<String, dynamic> payload, {
    required Map<String, dynamic> session,
  }) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.movementSubmit,
      payload: payload,
    );
    // Слепок — до отправки: отказ может прийти и сразу, и позже, из движка синхронизации.
    await _sent.save(operationId, session);
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) {
      return (
        operationId: operationId,
        result: const Right<Failure, void>(null),
      );
    }
    return (operationId: operationId, result: await _sync.sendOne(operation));
  }

  @override
  Future<ReopenOutcome> reopenRejected(String operationId) async {
    if (await _drafts.load() != null) return ReopenOutcome.draftBusy;
    final session = await _sent.load(operationId);
    if (session == null) return ReopenOutcome.lost;
    final operation = await _outbox.byOperationId(operationId);
    // Новый документ: тот же идентификатор сервер мог бы счесть уже проведённым другим путём,
    // а исправленный сеанс — это новая отправка.
    await _drafts.save({
      ...session,
      'movement_id': _ids.newId(),
      'fix_reason': operation?.lastError,
    });
    await _outbox.discard(operationId);
    return ReopenOutcome.reopened;
  }

  @override
  Future<Map<String, dynamic>?> loadDraft() => _drafts.load();

  @override
  Future<void> saveDraft(Map<String, dynamic> draft) => _drafts.save(draft);

  @override
  Future<void> clearDraft() => _drafts.clear();
}
