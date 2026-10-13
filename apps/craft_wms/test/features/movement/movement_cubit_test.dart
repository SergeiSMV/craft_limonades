import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/movement/domain/movement_repository.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_cubit.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_state.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Репозиторий в памяти: черновик (через JSON, как в базе) и отправка с заданным исходом.
class _FakeRepo implements MovementRepository {
  Map<String, dynamic>? draft;
  final sent = <Map<String, dynamic>>[];
  Either<Failure, void> result = const Right(null);

  @override
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload) async {
    sent.add(payload);
    return result;
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

/// Эталон формата — тот же файл, что применяет настоящий роутер сервера (P6-03).
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

  ContentLine line(double qty, {String d = date}) => ContentLine(
    goodId: good,
    goodName: 'Кальмар',
    goodCode: '16121',
    uom: 'шт',
    productionDate: d,
    qty: qty,
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
    'клиент собирает сеанс ровно в формате эталона — настоящим потоком сканов',
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
      // Россыпь, положенная в этом же сеансе, — в переехавший короб.
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
    'ячейка приёмки, чужой склад, короб на месте, короб в короб — подсказки',
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

  test('товар без источника и при товаре в руках — подсказки', () async {
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

  test('товар туда же нельзя; тот же путь — одна строка с суммой', () async {
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

  test('ячейка короба — последняя, куда его перенёс сеанс', () async {
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

  test('исход отправки: нет связи — в очереди, отказ — с причиной', () async {
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

  test(
    'ярлык, которого нет: со связью — недействителен, без связи — не проверить',
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
    'короб, выбранный вручную, помечается — карточка предложит перепечатать ярлык',
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

  test('с товаром в руках найденный вручную короб — приёмник', () async {
    final c = await started();
    c.onCell(cell3, loose: [line(5)]);
    c.takeGoods(line(5), 2);
    c.onBox(box(box1), cell2, manual: true);
    expect(c.state.hold, isNull);
    expect(c.state.lines.single.to.loadUnitId, box1);
    await c.close();
  });
}
