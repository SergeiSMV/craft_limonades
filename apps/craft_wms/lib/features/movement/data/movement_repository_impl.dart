import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/draft_slot.dart';
import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
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
  MovementRepositoryImpl(this._outbox, this._sync, this._drafts);

  final OutboxRepository _outbox;
  final SyncEngine _sync;
  final MovementDraftStore _drafts;

  @override
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload) async {
    final operationId = await _outbox.enqueue(
      kind: OutboxKind.movementSubmit,
      payload: payload,
    );
    final operation = await _outbox.byOperationId(operationId);
    if (operation == null) return const Right(null);
    return _sync.sendOne(operation);
  }

  @override
  Future<Map<String, dynamic>?> loadDraft() => _drafts.load();

  @override
  Future<void> saveDraft(Map<String, dynamic> draft) => _drafts.save(draft);

  @override
  Future<void> clearDraft() => _drafts.clear();
}
