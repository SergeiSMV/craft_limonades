import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/domain/problems/problems_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:craft_wms/portal/data/problems_repository_impl.dart';

import '../support/fake_dio_adapter.dart';

ResponseBody _json(String body, int status) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// P6-07-3: «Проблемы склада» в портале - разбор списка и тело решения.
void main() {
  late Dio dio;

  setUp(() => dio = Dio(BaseOptions(baseUrl: 'https://api.test')));

  test('список: короб, товар, допустимые решения, решённая с заданием', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'GET ${ApiConst.problems}': (_) => _json(
        '[{"id":"p1","created_at":"2026-10-21T08:00:00Z","created_by":"Иванов",'
        '"cell_address":"M1-5-3","load_unit_id":"6f1c2b3a-0d4e-4f5a-8b6c-7d8e9fa0b1c2",'
        '"reason":"expired","comment":"","from_warehouse":"Основной","to_warehouse":"Брак",'
        '"items":[{"good_code":"00-1","good_name":"Сыр","production_date":"2026-08-21",'
        '"qty":"12.000","cell_address":"M1-5-3"}],"reason_name":"Просрок",'
        '"resolutions":[{"id":"r1","name":"Списать","action":"write_off","is_active":true},'
        '{"id":"r3","name":"Возврат поставщику","action":"supplier_return","is_active":true}],'
        '"suggested_supplier_id":"s1","status":"open"},'
        '{"id":"p2","created_at":"2026-10-20T08:00:00Z","cell_address":"A","reason":"other",'
        '"comment":"развакуум","from_warehouse":"Основной","to_warehouse":"Брак","items":[],'
        '"resolutions":[],"status":"resolved","resolution_name":"Возврат поставщику",'
        '"decision":"supplier_return","supplier_name":"ООО Вкуснярики","return_task_number":57,'
        '"resolved_by":"Петров","resolved_at":"2026-10-21T09:00:00Z"}]',
        200,
      ),
    });
    final res = await ProblemsRepositoryImpl(dio).list();
    expect(res.isRight, isTrue);
    final [box, done] = res.right;
    expect(box.loadUnitCode, '9FA0B1C2');
    expect(box.items.single.qty, 12);
    expect(box.reasonName, 'Просрок');
    expect(
      [for (final r in box.resolutions) r.action],
      [ProblemDecision.writeOff, ProblemDecision.supplierReturn],
    );
    expect(done.resolutionName, 'Возврат поставщику');
    expect(box.suggestedSupplierId, 's1');
    expect(box.resolved, isFalse);
    expect(done.resolved, isTrue);
    expect(done.returnTaskNumber, 57);
    expect(done.resolvedAt, isNotNull);
  });

  test('решение: поля только своего вида; отказ - текст сервера', () async {
    final adapter = RecordingAdapter({
      'POST ${ApiConst.problemResolve('p1')}': (_) =>
          ResponseBody.fromString('', 204),
      'POST ${ApiConst.problemResolve('p2')}': (_) =>
          _json('{"error":"по проблеме уже принято решение"}', 409),
    });
    dio.httpClientAdapter = adapter;
    final repo = ProblemsRepositoryImpl(dio);

    final ok = await repo.resolve('p1', (
      resolutionId: 'r1',
      decision: ProblemDecision.writeOff,
      docNumber: 'СП-1',
      docDate: '2026-10-21',
      supplierId: 's1',
    ));
    expect(ok.isRight, isTrue);
    expect(adapter.requests.first.data, {
      'resolution_id': 'r1',
      'decision': 'write_off',
      'doc_number': 'СП-1',
      'doc_date': '2026-10-21',
    });

    // Пересорт (ADHOC-53) уходит с документом пересортицы, как списание.
    await repo.resolve('p1', (
      resolutionId: 'r4',
      decision: ProblemDecision.regrade,
      docNumber: 'ПС-7',
      docDate: '2026-10-28',
      supplierId: 's1',
    ));
    expect(adapter.requests.last.data, {
      'resolution_id': 'r4',
      'decision': 'regrade',
      'doc_number': 'ПС-7',
      'doc_date': '2026-10-28',
    });

    final refused = await repo.resolve('p2', (
      resolutionId: 'r2',
      decision: ProblemDecision.place,
      docNumber: '',
      docDate: '',
      supplierId: '',
    ));
    expect(
      refused.left,
      const Failure.server(409, 'по проблеме уже принято решение'),
    );
    expect(adapter.requests.last.data, {
      'resolution_id': 'r2',
      'decision': 'place',
    });
  });
}
