import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/outbox/sent_sessions.dart';
import 'package:craft_wms/features/putaway/data/putaway_draft_store.dart';
import 'package:craft_wms/features/putaway/data/putaway_repository.dart';
import 'package:craft_wms/features/putaway/presentation/bloc/putaway_cubit.dart';
import 'package:craft_wms/features/putaway/presentation/bloc/putaway_models.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements PutawayRepository {}

class _FixedIds extends Mock implements LoadUnitIdGenerator {}

/// Эталон формата - тот же файл, что применяет настоящий роутер сервера (P5-02-1).
const _fixturePath = '../backend/internal/handler/testdata/putaway_submit.json';

void main() {
  late AppDatabase db;
  late PutawayDraftStore drafts;
  late _FixedIds ids;

  const warehouse = '4d000000-0000-4000-8000-0000000000a1';
  const box = '4d000000-0000-4000-8000-000000000004';
  const good = TaskGood(
    id: '4d000000-0000-4000-8000-0000000000c1',
    code: '16121',
    name: 'Кальмар',
    uom: 'шт',
  );

  WarehouseTask task({String id = '4d000000-0000-4000-8000-0000000000e1'}) =>
      WarehouseTask(
        id: id,
        number: 7,
        kind: TaskKind.putaway,
        status: TaskStatus.inProgress,
        warehouseId: warehouse,
        createdAt: DateTime(2026, 10, 8),
        items: const [
          TaskItem(lineNo: 1, loadUnitId: box),
          TaskItem(
            lineNo: 2,
            good: good,
            productionDate: '02-09-2026',
            qty: '3',
            remaining: '3',
          ),
        ],
      );

  Cell cell(
    String id,
    String address, {
    bool isDefault = false,
    String wh = warehouse,
  }) => Cell(id: id, warehouseId: wh, address: address, isDefault: isDefault);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = PutawayDraftStore(db);
    ids = _FixedIds();
    when(() => ids.newId()).thenReturn('4d000000-0000-4000-8000-000000000003');
  });
  tearDown(() => db.close());

  PutawayCubit cubitFor(WarehouseTask t) =>
      PutawayCubit(_MockRepo(), drafts, ids, t);

  test('клиент собирает сеанс ровно в формате эталона', () async {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final expected =
        ((fixture['operations'] as List).single
            as Map<String, dynamic>)['payload'];
    final cubit = cubitFor(task());
    await cubit.init();

    // Тем же путём, что кладовщик: короб → ячейка, россыпь → количество → ячейка.
    cubit.pickBox(box.toUpperCase()); // регистр со скана не важен
    cubit.placeIn(cell('4d000000-0000-4000-8000-0000000000a4', 'M1-1-1-2'));
    cubit.pickLoose(cubit.state.task.items[1], 3);
    cubit.placeIn(cell('4d000000-0000-4000-8000-0000000000a3', 'M1-1-1-1'));

    final payload = jsonDecode(jsonEncode(PutawayCubit.payload(cubit.state)));
    expect(
      payload,
      expected,
      reason: 'формат разошёлся с testdata/putaway_submit.json',
    );
    await cubit.close();
  });

  test(
    'ячейка без взятого, ячейка приёмки и чужой склад - подсказки, а не строки',
    () async {
      final cubit = cubitFor(task());
      await cubit.init();

      cubit.placeIn(cell('c1', 'A-1'));
      expect(cubit.state.notice, isA<NoticePickFirst>());

      cubit.pickBox(box);
      cubit.placeIn(cell('c0', 'С-Н-П', isDefault: true));
      expect(cubit.state.notice, isA<NoticeReceivingCell>());
      cubit.placeIn(cell('c9', 'Z-1', wh: 'other'));
      expect(cubit.state.notice, isA<NoticeForeignCell>());

      expect(cubit.state.lines, isEmpty);
      expect(cubit.state.pick, isNotNull, reason: 'короб остаётся в руках');
      await cubit.close();
    },
  );

  test('короб не из задания и уже положенный - не берутся', () async {
    final cubit = cubitFor(task());
    await cubit.init();

    cubit.pickBox('00000000-0000-4000-8000-000000000000');
    expect(cubit.state.notice, isA<NoticeNotInTask>());

    cubit.pickBox(box);
    cubit.placeIn(cell('c1', 'A-1'));
    cubit.pickBox(box);
    expect(cubit.state.notice, isA<NoticeAlreadyPlaced>());
    expect(cubit.state.openBoxes, isEmpty);
    await cubit.close();
  });

  test(
    'короб ЧЗ - по коду с этикетки ЧЗ, в руках с кодом ЧЗ (CZ-06)',
    () async {
      const czCode = '00046012345678901234';
      final t = task();
      final cubit = cubitFor(
        t.copyWith(
          items: [
            t.items.first.copyWith(czCode: czCode),
            t.items.last,
          ],
        ),
      );
      await cubit.init();

      cubit.pickCzBox('00000000000000000001');
      expect(cubit.state.notice, isA<NoticeNotInTask>());

      cubit.pickCzBox(czCode);
      expect(cubit.state.pick?.loadUnitId, box);
      expect(cubit.state.pick?.czCode, czCode);
      await cubit.close();
    },
  );

  test(
    'россыпь марками ЧЗ: добавляются, повтор и перебор - подсказки, марки в теле (CZ-06)',
    () async {
      const m1 = '0104600000000017215A1';
      const m2 = '0104600000000017215A2';
      const m3 = '0104600000000017215A3';
      const m4 = '0104600000000017215A4';
      final cubit = cubitFor(task());
      await cubit.init();

      cubit.pickMarks([m1], good.id, '01-01-2026');
      expect(
        cubit.state.notice,
        isA<NoticeNotInTask>(),
        reason: 'партии нет в задании',
      );

      cubit.pickMarks([m1], good.id, '02-09-2026');
      cubit.pickMarks([m2], good.id, '02-09-2026');
      expect(cubit.state.pick?.marks, [m1, m2]);
      expect(cubit.state.pick?.qty, 2);
      cubit.pickMarks([m2], good.id, '02-09-2026');
      expect(cubit.state.notice, isA<NoticeMarkTaken>());
      cubit.pickMarks([m3, m4], good.id, '02-09-2026');
      expect(
        cubit.state.notice,
        isA<NoticeAlreadyPlaced>(),
        reason: 'в задании 3',
      );

      cubit.placeIn(cell('c1', 'A-1'));
      cubit.pickMarks([m3], good.id, '02-09-2026');
      cubit.placeIn(cell('c1', 'A-1'));
      final line = (PutawayCubit.payload(cubit.state)['lines'] as List).single;
      expect(line, containsPair('marks', [m1, m2, m3]));
      expect(line, containsPair('qty', 3.0));
      await cubit.close();
    },
  );

  test(
    'россыпь: остаток уменьшается, больше остатка не взять, одна ячейка - одна строка',
    () async {
      final cubit = cubitFor(task());
      await cubit.init();
      final loose = cubit.state.task.items[1];

      cubit.pickLoose(loose, 1);
      cubit.placeIn(cell('c1', 'A-1'));
      cubit.pickLoose(loose, 1);
      cubit.placeIn(cell('c1', 'A-1'));
      expect(cubit.state.lines, hasLength(1));
      expect(cubit.state.lines.single.pick.qty, 2);
      expect(cubit.state.looseLeft(loose), 1);

      cubit.pickLoose(loose, 2); // больше остатка
      expect(cubit.state.pick, isNull);
      await cubit.close();
    },
  );

  test(
    'незавершённый сеанс переживает перезапуск, чужой - не затирается',
    () async {
      final first = cubitFor(task());
      await first.init();
      first.pickBox(box);
      first.placeIn(cell('c1', 'A-1'));
      await first.draftWrites;
      await first.close();

      final again = cubitFor(task());
      await again.init();
      expect(again.state.lines, hasLength(1));
      expect(again.state.lines.single.cell.address, 'A-1');
      await again.close();

      // Другое задание: его сеанс не начинается, пока не решён чужой черновик. Отбросив его,
      // кладовщик отдаёт то задание в пул.
      final repo = _MockRepo();
      when(
        () => repo.releaseTask(any()),
      ).thenAnswer((_) async => const Right(null));
      final other = PutawayCubit(repo, drafts, ids, task(id: 'другое'));
      await other.init();
      expect(other.state.foreignDraftNumber, 7);
      await other.discardForeignDraft();
      verify(
        () => repo.releaseTask('4d000000-0000-4000-8000-0000000000e1'),
      ).called(1);
      expect(other.state.notice, isNull);
      await other.draftWrites;
      expect(other.state.foreignDraftNumber, isNull);
      expect((await drafts.load())?['task_id'], 'другое');
      await other.close();
    },
  );

  test(
    'без связи отброшенное задание не отдать - кладовщик узнаёт, что оно вернётся само',
    () async {
      final first = cubitFor(task());
      await first.init();
      first.pickBox(box);
      await first.draftWrites;
      await first.close();

      final repo = _MockRepo();
      when(
        () => repo.releaseTask(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final other = PutawayCubit(repo, drafts, ids, task(id: 'другое'));
      await other.init();
      await other.discardForeignDraft();

      expect(other.state.notice, const PutawayNotice.releaseOffline(7));
      expect(other.state.foreignDraftNumber, isNull);
      await other.close();
    },
  );

  // ADHOC-41 (долг 26): отказ с экрана итога возвращает сеанс в правку в том же задании -
  // с теми же строками, новым документом и причиной отказа.
  test('«Исправить»: сеанс снова черновик задания с причиной отказа', () async {
    final repo = _MockRepo();
    final cubit = PutawayCubit(repo, drafts, ids, task());
    await cubit.init();
    cubit.pickBox(box);
    cubit.placeIn(cell('4d000000-0000-4000-8000-0000000000a4', 'M1-1-1-2'));

    Map<String, dynamic>? sentSession;
    when(
      () => repo.submit(
        payload: any(named: 'payload'),
        session: any(named: 'session'),
        taskId: any(named: 'taskId'),
        boxes: any(named: 'boxes'),
        loose: any(named: 'loose'),
      ),
    ).thenAnswer((inv) async {
      sentSession = inv.namedArguments[#session] as Map<String, dynamic>;
      return (
        operationId: 'op-1',
        result: const Left<Failure, void>(
          RejectedFailure('Отклонено строк: 1 из 1'),
        ),
      );
    });
    // Как настоящий репозиторий: слепок - в черновик с новым документом и причиной.
    when(() => repo.reopenRejected('op-1')).thenAnswer((_) async {
      await drafts.save({
        ...jsonDecode(jsonEncode(sentSession)) as Map<String, dynamic>,
        'putaway_id': 'new-putaway-id',
        'fix_reason': 'Отклонено строк: 1 из 1',
      });
      return (ReopenOutcome.reopened, 7);
    });

    await cubit.submit();
    expect(cubit.state.outcome, PutawayOutcome.rejected);
    expect(cubit.state.rejectedOperationId, 'op-1');

    await cubit.fixRejected();
    expect(cubit.state.outcome, isNull);
    expect(cubit.state.lines.length, 1);
    expect(cubit.state.putawayId, 'new-putaway-id');
    expect(cubit.state.fixReason, 'Отклонено строк: 1 из 1');
    expect(
      cubit.state.foreignDraftNumber,
      isNull,
      reason: 'черновик своего задания',
    );
    await cubit.close();
  });
}
