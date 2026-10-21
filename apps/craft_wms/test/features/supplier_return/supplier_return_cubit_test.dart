import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/features/supplier_return/domain/supplier_return_repository.dart';
import 'package:craft_wms/features/supplier_return/presentation/bloc/supplier_return_cubit.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements SupplierReturnRepository {}

class _FixedIds extends Mock implements LoadUnitIdGenerator {}

/// Эталон формата — тот же файл, что применяет настоящий роутер сервера (ADHOC-31).
const _fixturePath = '../backend/internal/handler/testdata/return_submit.json';

/// ADHOC-31: сеанс отгрузки возврата поставщику на ТСД.
void main() {
  late _MockRepo repo;
  late _FixedIds ids;

  const warehouse = '7f000000-0000-4000-8000-0000000000a1';
  const boxProblem = '7f000000-0000-4000-8000-000000000001';
  const looseProblem = '7f000000-0000-4000-8000-000000000002';
  const box = '7f000000-0000-4000-8000-000000000004';
  const good = TaskGood(id: 'g1', code: '16121', name: 'Кальмар', uom: 'шт');

  // Идентификатор задания выдаёт сервер — в эталоне на его месте `TASK`.
  final task = WarehouseTask(
    id: 'TASK',
    number: 7,
    kind: TaskKind.supplierReturn,
    status: TaskStatus.inProgress,
    warehouseId: warehouse,
    supplier: 'ООО «Вкуснярики»',
    createdAt: DateTime(2026, 10, 21),
    items: const [
      TaskItem(
        lineNo: 1,
        loadUnitId: box,
        problemId: boxProblem,
        cell: 'M1-1-1-1',
      ),
      TaskItem(
        lineNo: 2,
        good: good,
        productionDate: '01-09-2026',
        qty: '2',
        remaining: '2',
        problemId: looseProblem,
        cell: 'M1-1-1-1',
      ),
    ],
  );

  setUpAll(() => registerFallbackValue(<String>{}));

  setUp(() {
    repo = _MockRepo();
    ids = _FixedIds();
    when(() => ids.newId()).thenReturn('7f000000-0000-4000-8000-000000000010');
  });

  SupplierReturnCubit cubit() => SupplierReturnCubit(repo, ids, task);

  test('клиент собирает сеанс ровно в формате эталона', () async {
    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    final expected =
        ((fixture['operations'] as List).single
            as Map<String, dynamic>)['payload'];
    final c = cubit();

    // Тем же путём, что кладовщик: короб — сканом, товар — ячейка и штрихкод.
    c.scanBox(box.toUpperCase()); // регистр со скана не важен
    c.scanCell('M1-1-1-1');
    c.scanGood(good.id);
    expect(c.state.complete, isTrue);

    expect(
      jsonDecode(jsonEncode(SupplierReturnCubit.payload(c.state))),
      expected,
      reason: 'формат разошёлся с testdata/return_submit.json',
    );
    await c.close();
  });

  test(
    'чужое не отмечается, повтор — подсказка, касание снимает отметку',
    () async {
      final c = cubit();
      c.scanBox('ffffffff-0000-4000-8000-000000000000');
      expect(c.state.notice, ReturnNotice.boxNotInTask);
      c.clearNotice();
      c.scanBox(box);
      c.scanBox(box);
      expect(c.state.notice, ReturnNotice.alreadyChecked);
      c.toggle(task.items.first);
      expect(c.state.marked, isEmpty);
      await c.close();
    },
  );

  test('«Отгружено» — только целиком; итог по ответу отправки', () async {
    when(
      () => repo.submit(
        payload: any(named: 'payload'),
        taskId: any(named: 'taskId'),
        problemIds: any(named: 'problemIds'),
      ),
    ).thenAnswer((_) async => const Left(Failure.network()));
    final c = cubit();
    c.scanBox(box);
    await c.submit();
    verifyNever(
      () => repo.submit(
        payload: any(named: 'payload'),
        taskId: any(named: 'taskId'),
        problemIds: any(named: 'problemIds'),
      ),
    );

    c.scanCell('M1-1-1-1');
    c.toggle(task.items.last);
    await c.submit();
    expect(c.state.outcome, ReturnOutcome.queued);
    await c.close();

    when(
      () => repo.submit(
        payload: any(named: 'payload'),
        taskId: any(named: 'taskId'),
        problemIds: any(named: 'problemIds'),
      ),
    ).thenAnswer(
      (_) async => const Left(Failure.rejected('позиция уже отгружена')),
    );
    final r = cubit()
      ..scanCell('M1-1-1-1')
      ..toggle(task.items.first)
      ..toggle(task.items.last);
    await r.submit();
    expect(r.state.outcome, ReturnOutcome.rejected);
    expect(r.state.rejectReason, 'позиция уже отгружена');
    await r.close();
  });

  test(
    'штрихкод без ячейки не отмечает: позиция серая, подсказка — какую ячейку',
    () async {
      final c = cubit();
      expect(c.state.isActive(task.items.last), isFalse);

      c.scanGood(good.id);
      expect(c.state.marked, isEmpty);
      expect(c.state.notice, ReturnNotice.needCell);
      expect(c.state.noticeCell, 'M1-1-1-1');
      c.clearNotice();

      c.toggle(task.items.last); // касание серой — тоже подсказка
      expect(c.state.marked, isEmpty);
      expect(c.state.notice, ReturnNotice.needCell);
      c.clearNotice();

      c.scanCell('M9-9-9-9');
      expect(c.state.notice, ReturnNotice.cellNotInTask);
      expect(c.state.cell, isNull);
      c.clearNotice();

      c.scanCell('m1-1-1-1'); // регистр со скана не важен
      expect(c.state.isActive(task.items.last), isTrue);
      c.scanGood(good.id);
      expect(c.state.marked, {looseProblem});
      await c.close();
    },
  );
}
