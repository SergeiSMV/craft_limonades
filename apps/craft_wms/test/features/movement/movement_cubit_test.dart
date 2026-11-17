import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/outbox/sent_sessions.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/movement/domain/movement_models.dart';
import 'package:craft_wms/features/movement/domain/movement_repository.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_cubit.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_state.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Репозиторий в памяти: черновик (через JSON, как в базе), отправка с заданным исходом и
/// слепки отправленных сеансов (ADHOC-41) - с той же логикой «Исправить», что у настоящего.
class _FakeRepo implements MovementRepository {
  Map<String, dynamic>? draft;
  final sent = <Map<String, dynamic>>[];
  final sessions = <String, Map<String, dynamic>>{};
  Either<Failure, void> result = const Right(null);

  @override
  Future<({String operationId, Either<Failure, void> result})> submit(
    Map<String, dynamic> payload, {
    required Map<String, dynamic> session,
  }) async {
    sent.add(payload);
    final id = 'op-${sent.length}';
    sessions[id] = jsonDecode(jsonEncode(session)) as Map<String, dynamic>;
    return (operationId: id, result: result);
  }

  @override
  Future<ReopenOutcome> reopenRejected(String operationId) async {
    if (draft != null) return ReopenOutcome.draftBusy;
    final session = sessions.remove(operationId);
    if (session == null) return ReopenOutcome.lost;
    final reason = switch (result) {
      Left(value: RejectedFailure(:final reason)) => reason,
      _ => null,
    };
    await saveDraft({
      ...session,
      'movement_id': 'fixed-movement-id',
      'fix_reason': reason,
    });
    return ReopenOutcome.reopened;
  }

  @override
  Future<Map<String, dynamic>?> loadDraft() async => draft;

  @override
  Future<void> saveDraft(Map<String, dynamic> d) async =>
      // Как настоящий слот черновика: слепок лежит строкой JSON.
      draft = jsonDecode(jsonEncode(d)) as Map<String, dynamic>;

  @override
  Future<void> clearDraft() async => draft = null;
}

class _FixedIds extends Mock implements LoadUnitIdGenerator {}

/// Эталон формата - тот же файл, что применяет настоящий роутер сервера (P6-03).
const _fixturePath =
    '../backend/internal/handler/testdata/movement_submit.json';

void main() {
  const warehouse = '6d000000-0000-4000-8000-0000000000a1';
  const box1 = '6d000000-0000-4000-8000-000000000004';
  const box2 = '6d000000-0000-4000-8000-000000000005';
  const good = '6d000000-0000-4000-8000-0000000000c1';
  const date = '01-09-2026';

  Cell cell(
    String id,
    String address, {
    bool isDefault = false,
    String wh = warehouse,
  }) => Cell(id: id, warehouseId: wh, address: address, isDefault: isDefault);

  final cell1 = cell('6d000000-0000-4000-8000-0000000000a3', 'M1-1-1-1');
  final cell2 = cell('6d000000-0000-4000-8000-0000000000a4', 'M1-1-1-2');
  final cell3 = cell('6d000000-0000-4000-8000-0000000000a5', 'M1-1-1-3');

  ContentLine line(
    double qty, {
    String d = date,
    String? iwh,
    String? iwhName,
  }) => ContentLine(
    goodId: good,
    goodName: 'Кальмар',
    goodCode: '16121',
    uom: 'шт',
    productionDate: d,
    qty: qty,
    internalWarehouseId: iwh,
    internalWarehouseName: iwhName,
  );

  LoadUnitView box(String id, {double qty = 12, bool live = true}) =>
      LoadUnitView(id: id, cellId: cell3.id, live: live, lines: [line(qty)]);

  late _FakeRepo repo;
  late _FixedIds ids;

  setUp(() {
    repo = _FakeRepo();
    ids = _FixedIds();
    when(() => ids.newId()).thenReturn('6d000000-0000-4000-8000-000000000006');
  });

  Future<MovementCubit> started() async {
    final c = MovementCubit(repo, ids);
    await c.init();
    return c;
  }

  test(
    'клиент собирает сеанс ровно в формате эталона - настоящим потоком сканов',
    () async {
      final fixture =
          jsonDecode(File(_fixturePath).readAsStringSync())
              as Map<String, dynamic>;
      final expected =
          ((fixture['operations'] as List).single
              as Map<String, dynamic>)['payload'];

      final c = await started();
      // Короб целиком: скан короба → скан ячейки.
      c.onBox(box(box1), cell3);
      c.onCell(cell2);
      // Товар из второго короба: скан короба → товар → ячейка (россыпь).
      c.onBox(box(box2), cell3);
      c.takeGoods(line(12), 3);
      c.onCell(cell1);
      // Россыпь, положенная в этом же сеансе, - в переехавший короб.
      c.onCell(cell1);
      c.takeGoods(c.candidates().single.$1, 2);
      c.onBox(box(box1), cell2);

      expect(c.state.hold, isNull);
      final payload = jsonDecode(jsonEncode(MovementCubit.payload(c.state)));
      expect(
        payload,
        expected,
        reason: 'формат разошёлся с testdata/movement_submit.json',
      );
      await c.close();
    },
  );

  test(
    'ячейка приёмки - источник только россыпи с меткой, приёмником не бывает',
    () async {
      const isolator = '6d000000-0000-4000-8000-0000000000e1';
      final receiving = cell('r', 'С-Н-П', isDefault: true);
      final c = await started();

      c.onCell(
        receiving,
        loose: [
          line(5),
          line(2, iwh: isolator, iwhName: 'Изолятор'),
        ],
      );
      final source = c.state.hold! as HoldSource;
      expect(c.state.candidates(source).map((e) => e.$2), [2]);
      expect(
        c.state.candidates(source).single.$1.internalWarehouseId,
        isolator,
      );

      c.takeGoods(c.state.candidates(source).single.$1, 2);
      c.onCell(receiving);
      expect(c.state.notice, isA<NoticeReceivingCell>());
      c.onCell(cell1);
      expect(c.state.lines.single.internalWarehouseId, isolator);
      expect(c.state.lines.single.from.cellId, 'r');
      await c.close();
    },
  );

  test(
    'ячейка приёмки, чужой склад, короб на месте, короб в короб - подсказки',
    () async {
      final c = await started();

      c.onCell(cell('r', 'С-Н-П', isDefault: true), loose: [line(5)]);
      expect(c.state.notice, isA<NoticeReceivingCell>());

      c.onBox(box(box1), cell3);
      c.onBox(box(box2), cell3);
      expect(c.state.notice, isA<NoticeBoxIntoBox>());
      c.onCell(cell3);
      expect(c.state.notice, isA<NoticeSameCell>());
      c.onCell(cell('z', 'Z-1', wh: 'другой'));
      expect(c.state.notice, isA<NoticeForeignCell>());

      expect(c.state.lines, isEmpty);
      expect(c.state.hold, isA<HoldSource>(), reason: 'короб остаётся в руках');
      await c.close();
    },
  );

  test('пустой короб и ячейка без россыпи источником не берутся', () async {
    final c = await started();

    c.onBox(box(box1, live: false), cell3);
    expect(c.state.notice, isA<NoticeBoxEmpty>());
    c.onBox(box(box1), null);
    expect(c.state.notice, isA<NoticeBoxEmpty>());
    c.onCell(cell1);
    expect(c.state.notice, isA<NoticeNoLoose>());
    expect(c.state.hold, isNull);
    await c.close();
  });

  test('товар без источника и при товаре в руках - подсказки', () async {
    final c = await started();

    c.goodWithoutSource();
    expect(c.state.notice, isA<NoticeSourceFirst>());
    c.onCell(cell3, loose: [line(5)]);
    c.takeGoods(line(5), 1);
    c.goodWithoutSource();
    expect(c.state.notice, isA<NoticePutFirst>());
    await c.close();
  });

  test(
    'доступное считает сеанс: больше остатка не взять, взятое уменьшает источник',
    () async {
      final c = await started();

      c.onCell(
        cell3,
        loose: [
          line(5),
          line(2, d: '02-09-2026'),
        ],
      );
      expect(c.candidates(goodId: good).length, 2, reason: 'две партии');
      c.takeGoods(line(5), 6);
      expect(
        c.state.hold,
        isA<HoldSource>(),
        reason: 'больше лежащего не взять',
      );

      c.takeGoods(line(5), 4);
      c.onCell(cell1);
      c.onCell(
        cell3,
        loose: [
          line(5),
          line(2, d: '02-09-2026'),
        ],
      );
      final left = {for (final o in c.candidates()) o.$1.productionDate: o.$2};
      expect(left, {date: 1, '02-09-2026': 2});
      await c.close();
    },
  );

  test('товар туда же нельзя; тот же путь - одна строка с суммой', () async {
    final c = await started();

    c.onCell(cell3, loose: [line(5)]);
    c.takeGoods(line(5), 2);
    c.onCell(cell3);
    expect(c.state.notice, isA<NoticeSamePlace>());

    c.onCell(cell1);
    c.onCell(cell3, loose: [line(5)]);
    c.takeGoods(line(5), 1);
    c.onCell(cell1);
    expect(c.state.lines.single.qty, 3);
    expect(c.state.notice, isA<NoticeMoved>());
    await c.close();
  });

  test('ячейка короба - последняя, куда его перенёс сеанс', () async {
    final c = await started();

    c.onBox(box(box1), cell3);
    c.onCell(cell2);
    expect(c.state.boxCellInSession(box1), cell2.id);
    expect(c.state.boxCellInSession(box2), isNull);
    await c.close();
  });

  test(
    'черновик: строки переживают перезапуск, итог стирает черновик',
    () async {
      final c = await started();
      c.onBox(box(box1), cell3);
      c.onCell(cell2);
      await c.draftWrites;
      expect(repo.draft, isNotNull);
      await c.close();

      final again = await started();
      expect(again.state.lines.length, 1);
      expect(again.state.warehouseId, warehouse);
      await again.submit();
      await again.draftWrites;
      expect(again.state.outcome, MoveOutcome.posted);
      expect(repo.draft, isNull);
      await again.close();
    },
  );

  test('исход отправки: нет связи - в очереди, отказ - с причиной', () async {
    final c = await started();
    c.onBox(box(box1), cell3);
    expect(c.state.canSubmit, isFalse, reason: 'в руках короб');
    c.onCell(cell2);

    repo.result = const Left(NetworkFailure());
    await c.submit();
    expect(c.state.outcome, MoveOutcome.queued);
    await c.close();

    final r = await started();
    r.onBox(box(box1), cell3);
    r.onCell(cell2);
    repo.result = const Left(RejectedFailure('not enough goods at the source'));
    await r.submit();
    expect(r.state.outcome, MoveOutcome.rejected);
    expect(r.state.rejectReason, 'not enough goods at the source');
    await r.close();
  });

  // ADHOC-41 (долг 26): отклонённый сеанс возвращается в правку теми же строками, с новым
  // документом и причиной отказа на экране; повторная отправка идёт уже новым документом.
  test(
    '«Исправить»: отказ снова черновик с причиной, отправка - новым документом',
    () async {
      final c = await started();
      c.onBox(box(box1), cell3);
      c.onCell(cell2);
      final firstId = c.state.movementId;
      repo.result = const Left(RejectedFailure('Отклонено строк: 1 из 1'));
      await c.submit();
      expect(c.state.outcome, MoveOutcome.rejected);
      expect(c.state.rejectedOperationId, 'op-1');

      await c.fixRejected();
      expect(c.state.outcome, isNull);
      expect(c.state.lines.length, 1, reason: 'строки сеанса вернулись');
      expect(c.state.movementId, 'fixed-movement-id');
      expect(c.state.movementId, isNot(firstId));
      expect(c.state.fixReason, 'Отклонено строк: 1 из 1');
      await c.draftWrites;
      expect(repo.draft?['fix_reason'], 'Отклонено строк: 1 из 1');

      repo.result = const Right(null);
      await c.submit();
      expect(c.state.outcome, MoveOutcome.posted);
      expect(repo.sent.last['movement_id'], 'fixed-movement-id');
      await c.close();
    },
  );

  test(
    'ярлык, которого нет: со связью - недействителен, без связи - не проверить',
    () async {
      final c = await started();
      c.boxNotFound(offline: false);
      expect(c.state.notice, isA<NoticeLabelInvalid>());
      c.boxNotFound(offline: true);
      expect(c.state.notice, isA<NoticeBoxUnknownOffline>());
      await c.close();
    },
  );

  test(
    'короб, выбранный вручную, помечается - карточка предложит перепечатать ярлык',
    () async {
      final c = await started();
      c.onBox(box(box1), cell3, manual: true);
      expect((c.state.hold! as HoldSource).manual, isTrue);
      c.dropHold();
      c.onBox(box(box1), cell3);
      expect((c.state.hold! as HoldSource).manual, isFalse);
      await c.close();
    },
  );

  test('с товаром в руках найденный вручную короб - приёмник', () async {
    final c = await started();
    c.onCell(cell3, loose: [line(5)]);
    c.takeGoods(line(5), 2);
    c.onBox(box(box1), cell2, manual: true);
    expect(c.state.hold, isNull);
    expect(c.state.lines.single.to.loadUnitId, box1);
    await c.close();
  });

  test(
    'брак и основной товар одной партии - раздельно; брак не кладётся в основной короб',
    () async {
      const defect = 'e0000000-0000-4000-8000-0000000000de';
      ContentLine defectLine(double qty) => ContentLine(
        goodId: good,
        goodName: 'Кальмар',
        uom: 'шт',
        productionDate: date,
        qty: qty,
        internalWarehouseId: defect,
        internalWarehouseName: 'Брак',
      );
      final c = await started();
      c.onCell(cell1, loose: [line(5), defectLine(2)]);
      final hold = c.state.hold! as HoldSource;
      expect(c.state.available(hold, good, date), 5);
      expect(c.state.available(hold, good, date, warehouseId: defect), 2);
      expect(c.candidates().map((o) => o.$1.internalWarehouseId), [
        null,
        defect,
      ]);

      c.takeGoods(defectLine(2), 2);
      c.onBox(box(box1), cell3);
      expect(c.state.notice, const MoveNotice.warehouseMismatch());
      expect(c.state.lines, isEmpty);

      c.onCell(cell2);
      final payload = MovementCubit.payload(c.state);
      final l = (payload['lines'] as List).single as Map<String, dynamic>;
      expect(l['internal_warehouse_id'], defect);
      expect(l['from_cell_id'], cell1.id);
      expect(c.state.lines.single.internalWarehouseName, 'Брак');
      await c.close();
    },
  );

  group('марки ЧЗ (CZ-06)', () {
    const czFixture =
        '../backend/internal/handler/testdata/movement_submit_cz.json';
    const czWh = '6e000000-0000-4000-8000-0000000000a1';
    const czGood = '6e000000-0000-4000-8000-0000000000c1';
    const czBox = '6e000000-0000-4000-8000-000000000004';
    const m1 = '0104600000000020215M1';
    const m2 = '0104600000000020215M2';
    const m3 = '0104600000000020215M3';
    const beer = MoveGood(id: czGood, name: 'Пиво', code: '16121', uom: 'шт');
    final czCell1 = Cell(
      id: '6e000000-0000-4000-8000-0000000000a3',
      warehouseId: czWh,
      address: 'M1-1-1-1',
    );
    final czCell2 = Cell(
      id: '6e000000-0000-4000-8000-0000000000a5',
      warehouseId: czWh,
      address: 'M1-1-1-2',
    );
    final loose = MovePlace(cellId: czCell1.id, cellAddress: czCell1.address);
    final inBox = MovePlace(
      cellId: czCell2.id,
      cellAddress: czCell2.address,
      loadUnitId: czBox,
    );
    final boxView = LoadUnitView(
      id: czBox,
      cellId: czCell2.id,
      live: true,
      czCode: '00046000000000000020',
      lines: [line(12)],
    );

    void take(MovementCubit c, List<String> marks, MovePlace from, Cell cell) =>
        c.takeMarks(
          marks: marks,
          good: beer,
          productionDate: date,
          from: from,
          cell: cell,
        );

    test('клиент собирает сеанс марками ровно в формате эталона', () async {
      when(
        () => ids.newId(),
      ).thenReturn('6e000000-0000-4000-8000-000000000006');
      final fixture =
          jsonDecode(File(czFixture).readAsStringSync())
              as Map<String, dynamic>;
      final expected =
          ((fixture['operations'] as List).single
              as Map<String, dynamic>)['payload'];

      final c = await started();
      // Две марки россыпью по одной - в короб ЧЗ.
      take(c, [m1], loose, czCell1);
      take(c, [m2], loose, czCell1);
      expect((c.state.hold! as HoldGoods).qty, 2);
      c.onBox(boxView, czCell2);
      // Марка, лежавшая в коробе ЧЗ, - россыпью в M1-1-1-1.
      take(c, [m3], inBox, czCell2);
      c.onCell(czCell1);

      expect(c.state.hold, isNull);
      expect(
        jsonDecode(jsonEncode(MovementCubit.payload(c.state))),
        expected,
        reason: 'формат разошёлся с testdata/movement_submit_cz.json',
      );
      expect(c.state.markPlaceInSession(m1)?.loadUnitId, czBox);
      expect(c.state.markPlaceInSession(m3)?.cellId, czCell1.id);
      await c.close();
    });

    test(
      'повтор, чужое место, товар в руках, ШК маркируемого - подсказки',
      () async {
        final c = await started();
        take(c, [m1], loose, czCell1);
        take(c, [m1], loose, czCell1);
        expect(c.state.notice, const MoveNotice.markTaken());
        take(c, [m3], inBox, czCell2);
        expect(c.state.notice, const MoveNotice.markOtherGoods());
        c.dropHold();

        // Источник в руках - ячейка; марка лежит в коробе.
        c.onCell(czCell1, loose: [line(5)]);
        take(c, [m3], inBox, czCell2);
        expect(c.state.notice, const MoveNotice.notInSource());

        // Товар взят количеством - марку к нему не добавить.
        c.takeGoods(line(5), 1);
        take(c, [m1], loose, czCell1);
        expect(c.state.notice, const MoveNotice.putFirst());

        c.markRequired();
        expect(c.state.notice, const MoveNotice.scanMark());

        // Ячейка приёмки - не источник и для марок.
        c.dropHold();
        final receiving = Cell(
          id: 'r',
          warehouseId: czWh,
          address: 'С-Н-П',
          isDefault: true,
        );
        take(c, [m1], MovePlace(cellId: 'r', cellAddress: 'С-Н-П'), receiving);
        expect(c.state.notice, const MoveNotice.receivingCell());
        expect(c.state.hold, isNull);

        // Марки с меткой склада ячейка приёмки отдаёт (ADHOC-55).
        c.takeMarks(
          marks: [m1],
          good: beer,
          productionDate: date,
          from: MovePlace(cellId: 'r', cellAddress: 'С-Н-П'),
          cell: receiving,
          internalWarehouseId: '6e000000-0000-4000-8000-0000000000e1',
          internalWarehouseName: 'Изолятор',
        );
        expect(c.state.hold, isA<HoldGoods>());
        await c.close();
      },
    );
  });
}
