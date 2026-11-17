import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/sent_sessions.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/movement/data/movement_repository_impl.dart';
import 'package:craft_wms/features/putaway/data/putaway_draft_store.dart';
import 'package:craft_wms/features/putaway/data/putaway_repository.dart';
import 'package:craft_wms/features/tasks/data/tasks_cache.dart';
import 'package:craft_wms/features/tasks/domain/tasks_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockSync extends Mock implements SyncEngine {}

class _MockTasks extends Mock implements TasksRepository {}

class _FixedIds extends Mock implements LoadUnitIdGenerator {}

/// Слепки отправленных сеансов и «Исправить» (ADHOC-41, долг 26) - на настоящей локальной базе.
void main() {
  late AppDatabase db;
  late OutboxRepository outbox;
  late SentSessionStore sent;
  late MovementDraftStore drafts;
  late MovementRepositoryImpl movement;

  const session = {
    'movement_id': 'old-movement-id',
    'warehouse_id': 'wh',
    'lines': <Object>[],
  };

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
    sent = SentSessionStore(db);
    drafts = MovementDraftStore(db);
    final ids = _FixedIds();
    when(ids.newId).thenReturn('new-movement-id');
    movement = MovementRepositoryImpl(outbox, _MockSync(), drafts, sent, ids);
  });
  tearDown(() => db.close());

  /// Отклонённая сервером операция перемещения со слепком сеанса.
  Future<String> rejected({bool withSession = true}) async {
    final id = await outbox.enqueue(
      kind: OutboxKind.movementSubmit,
      payload: {'movement_id': 'old-movement-id'},
    );
    if (withSession) await sent.save(id, session);
    await outbox.markRejected(id, 'Отклонено строк: 1 из 2');
    return id;
  }

  test(
    '«Исправить»: сеанс - черновик с новым документом и причиной, операции нет',
    () async {
      final id = await rejected();

      expect(await movement.reopenRejected(id), ReopenOutcome.reopened);

      final draft = await drafts.load();
      expect(draft?['movement_id'], 'new-movement-id');
      expect(draft?['warehouse_id'], 'wh');
      expect(draft?['fix_reason'], 'Отклонено строк: 1 из 2');
      expect(
        await outbox.byOperationId(id),
        isNull,
        reason: 'операция ушла из очереди',
      );
      expect(
        await sent.load(id),
        isNull,
        reason: 'слепок ушёл вместе с операцией',
      );
    },
  );

  test(
    'идёт другой сеанс - его черновик не затираем, операция остаётся',
    () async {
      final id = await rejected();
      await drafts.save({'movement_id': 'current', 'lines': <Object>[]});

      expect(await movement.reopenRejected(id), ReopenOutcome.draftBusy);

      expect((await drafts.load())?['movement_id'], 'current');
      expect(await outbox.byOperationId(id), isNotNull);
      expect(await sent.load(id), isNotNull);
    },
  );

  test(
    'слепка нет (операция старой сборки) - восстанавливать нечего',
    () async {
      final id = await rejected(withSession: false);
      expect(await movement.reopenRejected(id), ReopenOutcome.lost);
      expect(await drafts.load(), isNull);
    },
  );

  test('слепок живёт до подтверждения и уходит с «Отбросить»', () async {
    final accepted = await outbox.enqueue(
      kind: OutboxKind.movementSubmit,
      payload: {'movement_id': 'a'},
    );
    await sent.save(accepted, session);
    await outbox.markSent(accepted);
    expect(
      await sent.load(accepted),
      isNull,
      reason: 'принятое исправлять нечего',
    );

    final dropped = await rejected();
    await outbox.discard(dropped);
    expect(await sent.load(dropped), isNull);
  });

  test(
    'размещение: сеанс возвращается в своё задание, номер задания - для подсказки',
    () async {
      final putawayDrafts = PutawayDraftStore(db);
      final ids = _FixedIds();
      when(ids.newId).thenReturn('new-putaway-id');
      final putaway = PutawayRepository(
        outbox,
        _MockSync(),
        _MockTasks(),
        TasksCache(db),
        putawayDrafts,
        sent,
        ids,
      );
      final id = await outbox.enqueue(
        kind: OutboxKind.putawaySubmit,
        payload: {'putaway_id': 'old-putaway-id'},
      );
      await sent.save(id, {
        'task_id': 'task-7',
        'task_number': 7,
        'putaway_id': 'old-putaway-id',
        'lines': <Object>[],
        'pick': null,
      });
      await outbox.markRejected(id, 'Отклонено строк: 1 из 1');

      final (outcome, number) = await putaway.reopenRejected(id);
      expect(outcome, ReopenOutcome.reopened);
      expect(number, 7);
      final draft = await putawayDrafts.load();
      expect(draft?['task_id'], 'task-7');
      expect(draft?['putaway_id'], 'new-putaway-id');
      expect(draft?['fix_reason'], 'Отклонено строк: 1 из 1');
      expect(await outbox.byOperationId(id), isNull);
    },
  );
}
