import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/problems/problem_reasons.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/problems/domain/problem_photos.dart';
import 'package:craft_wms/features/problems/domain/problem_repository.dart';
import 'package:craft_wms/features/problems/presentation/bloc/problem_cubit.dart';
import 'package:craft_wms/features/problems/presentation/bloc/problem_state.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// Репозиторий в памяти: склады для пометки и отправка с заданным исходом.
class _FakeRepo implements ProblemRepository {
  final sent = <Map<String, dynamic>>[];
  Either<Failure, void> result = const Right(null);

  /// Id складов — коды справочника: эталон несёт их вместо id, которые выдаёт сервер.
  @override
  Future<List<InternalWarehouse>> markWarehouses() async => const [
    InternalWarehouse(
      id: 'DEFECT',
      code: 'DEFECT',
      name: 'Брак',
      isDefault: false,
    ),
    InternalWarehouse(
      id: 'ISOLATOR',
      code: 'ISOLATOR',
      name: 'Изолятор',
      isDefault: false,
    ),
  ];

  @override
  Future<List<ProblemReason>> markReasons() async => fallbackProblemReasons();

  @override
  Future<Either<Failure, void>> submit(Map<String, dynamic> payload) async {
    sent.add(payload);
    return result;
  }
}

/// Причина справочника по коду — из прежнего списка, как до первой синхронизации.
ProblemReason reason(String code) =>
    fallbackProblemReasons().firstWhere((r) => r.code == code);

class _Ids extends Mock implements LoadUnitIdGenerator {}

/// Очередь фото в памяти: что поставили и к какой проблеме (ADHOC-45).
class _FakePhotos implements ProblemPhotoRepository {
  final queued = <String, List<ProblemPhotoShot>>{};

  @override
  Future<void> enqueue(String problemId, List<ProblemPhotoShot> shots) async =>
      (queued[problemId] ??= []).addAll(shots);

  @override
  Future<void> upload() async {}

  @override
  Future<List<PendingProblemPhoto>> pendingOf(String problemId) async => [];

  @override
  Stream<int> watchPendingCount() => Stream.value(0);

  @override
  Future<Either<Failure, Uint8List>> fetch({
    required String problemId,
    required String photoId,
  }) async => const Left(Failure.network());
}

/// Камера, которая отдаёт заранее заданный снимок (`null` — съёмку отменили).
class _FakeCamera implements PhotoCamera {
  Uint8List? next = Uint8List.fromList([0xFF, 0xD8, 0xFF]);

  @override
  Future<Uint8List?> take() async => next;
}

/// Эталон формата — тот же файл, что применяет настоящий роутер сервера (P6-07-1).
const _fixturePath = '../backend/internal/handler/testdata/problem_submit.json';

/// «Проблемы склада» на ТСД (P6-07-2): одна проблема — одна операция `problem_submit`.
void main() {
  const warehouse = '7e000000-0000-4000-8000-0000000000a1';
  const good = '7e000000-0000-4000-8000-0000000000c1';
  const boxId = '7e000000-0000-4000-8000-000000000004';

  const cell = Cell(
    id: '7e000000-0000-4000-8000-0000000000a2',
    warehouseId: warehouse,
    address: 'M1-1-1-1',
  );
  const receiving = Cell(
    id: 'r',
    warehouseId: warehouse,
    address: 'С-Н-П',
    isDefault: true,
  );

  ContentLine line(double qty, {String? iwh}) => ContentLine(
    goodId: good,
    goodName: 'Кальмар',
    uom: 'шт',
    productionDate: '01-09-2026',
    qty: qty,
    internalWarehouseId: iwh,
  );

  LoadUnitView box({String? iwh, bool live = true}) => LoadUnitView(
    id: boxId,
    cellId: cell.id,
    live: live,
    lines: [line(12, iwh: iwh)],
    internalWarehouseId: iwh,
  );

  late _FakeRepo repo;
  late _Ids ids;
  late int seq;
  late _FakePhotos photos;
  late _FakeCamera camera;

  setUp(() {
    repo = _FakeRepo();
    photos = _FakePhotos();
    camera = _FakeCamera();
    ids = _Ids();
    seq = 0;
    when(
      () => ids.newId(),
    ).thenAnswer((_) => '7e000000-0000-4000-8000-00000000000${++seq}');
  });

  Future<ProblemCubit> started() async {
    final c = ProblemCubit(repo, ids, photos, camera);
    await c.init();
    return c;
  }

  test('клиент собирает обе проблемы ровно в формате эталона', () async {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final expected = [
      for (final op in fixture['operations'] as List)
        (op as Map<String, dynamic>)['payload'],
    ];

    final c = await started();
    // Россыпь в брак: скан ячейки → товар → 2 шт → «Брак» → бой → комментарий.
    c.onCell(
      cell,
      CellView(cellId: cell.id, address: cell.address, loose: [line(5)]),
    );
    c.chooseGoods(line(5), 2);
    c.setWarehouse('DEFECT');
    c.setReason(reason('breakage'));
    c.setComment('разбита при снятии с полки');
    await c.submit();
    expect(c.state.outcome, ProblemOutcome.posted);

    // Короб целиком в изолятор: скан короба → «Весь короб» → не наша марка → скан марки.
    c.next();
    c.onBox(box(), cell);
    c.chooseWholeBox();
    c.setWarehouse('ISOLATOR');
    c.setReason(reason(ProblemReasonCodes.foreignMark));
    c.setMark('0104600000000015215abcde');
    await c.submit();

    expect(
      jsonDecode(jsonEncode(repo.sent)),
      expected,
      reason: 'формат разошёлся с testdata/problem_submit.json',
    );
    await c.close();
  });

  test(
    'ячейка приёмки, пустой короб и пустая ячейка — подсказки, а не выбор',
    () async {
      final c = await started();
      c.onCell(receiving, const CellView(cellId: 'r', address: 'С-Н-П'));
      expect(c.state.notice, const ProblemNotice.receivingCell());
      c.onBox(box(live: false), cell);
      expect(c.state.notice, const ProblemNotice.boxEmpty());
      c.onCell(cell, CellView(cellId: cell.id, address: cell.address));
      expect(c.state.notice, const ProblemNotice.cellEmpty());
      expect(c.state.source, isNull);
      await c.close();
    },
  );

  test(
    'склад назначения — не тот, где товар уже лежит; единственный подставляется',
    () async {
      final c = await started();
      c.onBox(box(iwh: 'DEFECT'), cell);
      c.chooseWholeBox();
      expect(c.targetsFor(c.state.subject!).map((w) => w.id), ['ISOLATOR']);
      expect(c.state.toWarehouseId, 'ISOLATOR');

      // Часть бракованного короба — товар того же склада, из короба.
      c.back();
      c.chooseGoods(line(12, iwh: 'DEFECT'), 2);
      final payload = ProblemCubit.payload(
        c.state.copyWith(reason: reason('expired')),
      );
      expect(payload['from_load_unit_id'], boxId);
      expect(
        payload.containsKey('internal_warehouse_id'),
        isFalse,
        reason: 'склад короба знает сервер',
      );
      await c.close();
    },
  );

  test(
    'россыпь брака уходит со своим складом; «прочее» без комментария не фиксируется',
    () async {
      final c = await started();
      c.onCell(
        cell,
        CellView(
          cellId: cell.id,
          address: cell.address,
          loose: [line(3, iwh: 'DEFECT')],
        ),
      );
      c.chooseGoods(line(3, iwh: 'DEFECT'), 4);
      expect(c.state.subject, isNull, reason: 'больше, чем лежит, не берётся');
      c.chooseGoods(line(3, iwh: 'DEFECT'), 3);
      c.setReason(reason(ProblemReasonCodes.other));
      expect(c.state.canSubmit, isFalse);
      c.setComment('  ');
      expect(c.state.canSubmit, isFalse);
      c.setComment('этикетка размыта');
      expect(c.state.canSubmit, isTrue);
      expect(ProblemCubit.payload(c.state)['internal_warehouse_id'], 'DEFECT');
      await c.close();
    },
  );

  test('нет связи — в очереди; отказ по существу — с причиной', () async {
    final c = await started();
    c.onBox(box(), cell);
    c.chooseWholeBox();
    c.setWarehouse('DEFECT');
    c.setReason(reason('spoilage'));
    repo.result = const Left(Failure.network());
    await c.submit();
    expect(c.state.outcome, ProblemOutcome.queued);

    c.next();
    expect(
      c.state.reason?.code,
      'spoilage',
      reason: 'причина остаётся для следующей',
    );
    c.onBox(box(), cell);
    c.chooseWholeBox();
    c.setWarehouse('DEFECT');
    repo.result = const Left(
      Failure.rejected('goods already belong to the target internal warehouse'),
    );
    await c.submit();
    expect(c.state.outcome, ProblemOutcome.rejected);
    expect(c.state.rejectReason, contains('target'));
    await c.close();
  });

  test(
    'фото: не больше трёх, отмена съёмки — без снимка, убрать до фиксации',
    () async {
      final c = await started();
      camera.next = null;
      await c.takePhoto();
      expect(c.state.photos, isEmpty, reason: 'съёмку отменили');

      camera.next = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      for (var i = 0; i < 4; i++) {
        await c.takePhoto();
      }
      expect(c.state.photos, hasLength(kProblemPhotoMax));
      c.removePhoto(c.state.photos.first.id);
      expect(c.state.photos, hasLength(kProblemPhotoMax - 1));
      await c.close();
    },
  );

  test(
    'фото уходят в очередь вслед за проблемой — и без связи, но не после отказа',
    () async {
      final c = await started();
      c.onBox(box(), cell);
      c.chooseWholeBox();
      c.setWarehouse('DEFECT');
      c.setReason(reason('spoilage'));
      await c.takePhoto();
      await c.takePhoto();
      final problem = c.state.problemId!;
      repo.result = const Left(Failure.network());
      await c.submit();
      expect(photos.queued[problem], hasLength(2));

      c.next();
      c.onBox(box(), cell);
      c.chooseWholeBox();
      c.setWarehouse('DEFECT');
      await c.takePhoto();
      repo.result = const Left(Failure.rejected('нет'));
      await c.submit();
      expect(
        photos.queued.containsKey(c.state.problemId),
        isFalse,
        reason: 'отклонённой проблемы на сервере не будет',
      );
      await c.close();
    },
  );

  test(
    'марками ЧЗ: отмечаются, добавляются, повтор и чужое место — подсказки (CZ-06)',
    () async {
      const m1 = '0104600000000015215M1';
      const m2 = '0104600000000015215M2';
      final c = await started();
      c.chooseMarks(marks: [m1], line: line(1), cell: receiving);
      expect(c.state.notice, const ProblemNotice.receivingCell());

      c.chooseMarks(marks: [m1], line: line(1), cell: cell, box: box());
      c.chooseMarks(marks: [m2], line: line(1), cell: cell, box: box());
      final subject = c.state.subject! as SubjectGoods;
      expect(subject.marks, [m1, m2]);
      expect(subject.qty, 2);
      c.chooseMarks(marks: [m2], line: line(1), cell: cell, box: box());
      expect(c.state.notice, const ProblemNotice.markTaken());
      c.chooseMarks(
        marks: ['0104600000000015215M3'],
        line: line(1),
        cell: cell,
      );
      expect(c.state.notice, const ProblemNotice.markOtherGoods());

      c.setWarehouse('DEFECT');
      c.setReason(reason('breakage'));
      final p = ProblemCubit.payload(c.state);
      expect(p['from_load_unit_id'], boxId);
      expect(p['qty'], 2.0);
      expect(p['marks'], [m1, m2]);
      await c.close();
    },
  );
}
