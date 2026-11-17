import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/cz/data/cz_scan_dto.dart';
import 'package:craft_wms/features/cz/domain/cz_scan.dart';
import 'package:craft_wms/features/cz/domain/cz_scan_queue.dart';
import 'package:craft_wms/features/cz/domain/cz_stock_marks.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';

/// Эталон ответа пачки - общий с сервером (`cz_scan_http_test.go`).
Map<String, dynamic> _golden(String name) =>
    jsonDecode(
          File('../backend/internal/handler/testdata/$name').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// Сервер-подделка: каждая пачка ждёт, пока тест её отпустит; ответ - марка на каждый код.
class _FakeRepo implements CzScanRepository {
  final calls = <List<String>>[];
  final _gates = <Completer<void>>[];
  Failure? fail;

  /// Отпустить пачку [i].
  void release(int i) => _gates[i].complete();

  @override
  Future<Either<Failure, CzScanResult>> scan(String code) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, List<CzScanBatchItem>>> scanMany(
    List<String> codes,
  ) async {
    calls.add(codes);
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    final f = fail;
    if (f != null) return Left(f);
    return Right([
      for (final c in codes)
        CzScanBatchItem(
          requested: c,
          result: Right(CzScanResult(code: c, kind: CzCodeKind.unit)),
        ),
    ]);
  }
}

CzQueued<String?> _q(String code, [String? box]) =>
    CzQueued(code: code, key: code, target: box);

/// Очередь чтения ЧЗ пачками (ADHOC-70).
void main() {
  test(
    'сканы во время чтения уходят следующей пачкой, ответы - по порядку',
    () async {
      final repo = _FakeRepo();
      final queue = CzScanQueue<String?>(repo);
      final got = <List<String>>[];
      queue.results.listen(
        (b) => got.add([for (final r in b) '${r.item.code}@${r.item.target}']),
      );

      queue.add(_q('m1'));
      await Future<void>.delayed(Duration.zero);
      queue
        ..add(_q('m2', 'box'))
        ..add(_q('m3'))
        ..add(_q('m4', 'box'));
      expect(queue.pending, 4);
      expect(queue.holds('m3'), isTrue);
      expect(repo.calls, [
        ['m1'],
      ]);

      repo.release(0);
      await Future<void>.delayed(Duration.zero);
      expect(repo.calls.last, ['m2', 'm3', 'm4']);
      repo.release(1);
      await queue.whenIdle();

      expect(got, [
        ['m1@null'],
        ['m2@box', 'm3@null', 'm4@box'],
      ]);
      expect(queue.pending, 0);
      expect(queue.holds('m3'), isFalse);
    },
  );

  test('пачка не больше предела', () async {
    final repo = _FakeRepo();
    final queue = CzScanQueue<String?>(repo, maxBatch: 2);
    queue.results.listen((_) {});
    queue.add(_q('a'));
    await Future<void>.delayed(Duration.zero);
    for (final c in ['b', 'c', 'd']) {
      queue.add(_q(c));
    }
    repo.release(0);
    await Future<void>.delayed(Duration.zero);
    repo.release(1);
    await Future<void>.delayed(Duration.zero);
    repo.release(2);
    await queue.whenIdle();
    expect(repo.calls, [
      ['a'],
      ['b', 'c'],
      ['d'],
    ]);
  });

  test('без связи - отказ каждому коду пачки', () async {
    final repo = _FakeRepo()..fail = const Failure.network();
    final queue = CzScanQueue<String?>(repo);
    final results = <CzQueueResult<String?>>[];
    queue.results.listen(results.addAll);
    queue
      ..add(_q('m1'))
      ..add(_q('m2'));
    await Future<void>.delayed(Duration.zero);
    repo.release(0);
    await Future<void>.delayed(Duration.zero);
    repo.release(1);
    await queue.whenIdle();
    expect(results, hasLength(2));
    expect(results.every((r) => r.result.left is NetworkFailure), isTrue);
  });

  test(
    'ответ доходит до экрана раньше, чем коды уходят из «ждут ответа»',
    () async {
      final repo = _FakeRepo();
      final queue = CzScanQueue<String?>(repo);
      int? pendingAtDelivery;
      queue.results.listen((_) => pendingAtDelivery = queue.pending);
      queue.add(_q('m1'));
      await Future<void>.delayed(Duration.zero);
      repo.release(0);
      await queue.whenIdle();
      expect(pendingAtDelivery, 1);
      expect(queue.pending, 0);
    },
  );

  group('ответ пачки (эталон сервера cz_scan_batch.json)', () {
    test('скан и отказы по кодам - в порядке запроса', () {
      final items = czScanBatchFromJson(_golden('cz_scan_batch.json'));
      expect(items, hasLength(4));
      expect(items[0].requested, contains('0104612728200172215AmxPmd'));
      expect(items[0].result.right.kind, CzCodeKind.unit);
      expect(items[0].result.right.mark?.inStock, isTrue);
      expect(items[1].result.right.kind, CzCodeKind.box);
      expect(items[1].result.right.units, 2);
      final notFound = items[2].result.left as ServerFailure;
      expect(notFound.statusCode, 404);
      expect(notFound.message, 'код не найден в Честном знаке');
      expect((items[3].result.left as ServerFailure).statusCode, 400);
    });
  });

  group('марка на складе из ответа сервера', () {
    final golden = czScanFromJson(_golden('cz_scan_mark.json'));

    test('марка в коробе: товар, партия DD-MM-YYYY, короб', () {
      final m = stockMarkFromScan(golden, defaultWarehouseId: null)!;
      expect(m.cis, '0104612728200172215AmxPmd');
      expect(m.goodId, '11111111-0000-4000-8000-000000000001');
      expect(m.productionDate, '12-10-2026');
      expect(m.loadUnitId, '22222222-0000-4000-8000-000000000001');
      expect(m.cellId, isNull);
    });

    test('россыпью «Основного» - склад null, как в снимке', () {
      final j = _golden('cz_scan_mark.json');
      (j['mark'] as Map<String, dynamic>)
        ..remove('load_unit_id')
        ..['cell_id'] = 'c1'
        ..['internal_warehouse_id'] = 'main';
      final m = stockMarkFromScan(
        czScanFromJson(j),
        defaultWarehouseId: 'main',
      )!;
      expect(m.cellId, 'c1');
      expect(m.internalWarehouseId, isNull);
    });

    test('не на складе или нет товара - не марка склада', () {
      final gone = _golden('cz_scan_mark.json');
      (gone['mark'] as Map<String, dynamic>)['status'] = 'shipped';
      expect(
        stockMarkFromScan(czScanFromJson(gone), defaultWarehouseId: null),
        isNull,
      );
      final unknown = _golden('cz_scan_mark.json')..['mark'] = null;
      expect(
        stockMarkFromScan(czScanFromJson(unknown), defaultWarehouseId: null),
        isNull,
      );
    });
  });
}
