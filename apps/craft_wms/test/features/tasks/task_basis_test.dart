import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/utils/doc_number.dart';
import 'package:craft_wms/features/tasks/domain/tasks_models.dart';
import 'package:craft_wms/features/tasks/presentation/widgets/common/task_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Основание задания (ADHOC-23): документ поставщика, а у заданий до ADHOC-23 - приёмка по дате.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocaleSettings.useDeviceLocale);

  WarehouseTask task({
    String supplier = 'ИП Березин',
    String? number,
    String? date,
  }) => WarehouseTask(
    id: 't1',
    number: 7,
    kind: TaskKind.putaway,
    status: TaskStatus.fresh,
    warehouseId: 'w1',
    supplier: supplier,
    receivedAt: DateTime(2026, 10, 5, 12),
    docNumber: number,
    docDate: date,
    createdAt: DateTime(2026, 10, 5, 12),
  );

  test('с документом - номер и дата документа', () {
    expect(
      taskBasis(task(number: 'ТН-1042/2', date: '01-10-2026')),
      t.tasks.basisDoc(
        number: 'ТН-1042/2',
        date: '01.10.2026',
        supplier: 'ИП Березин',
      ),
    );
    expect(
      taskBasis(task(supplier: '', number: 'б/н', date: '01-10-2026')),
      t.tasks.basisDocNoSupplier(number: 'б/н', date: '01.10.2026'),
    );
  });

  test('без документа (до ADHOC-23) - приёмка по дате оприходования', () {
    expect(
      taskBasis(task()),
      t.tasks.basisReceipt(date: '05.10.2026', supplier: 'ИП Березин'),
    );
  });

  test('по решению «разместить» - номер проблемы склада (ADHOC-55)', () {
    final json = {
      'id': 't2',
      'number': 8,
      'kind': TaskKind.putaway,
      'status': TaskStatus.fresh,
      'warehouse_id': 'w1',
      'receipt_id': null,
      'supplier': '',
      'problem': {'id': 'p1', 'number': 9},
      'created_at': '2026-10-29T10:00:00Z',
    };
    final fromProblem = WarehouseTask.fromJson(json);
    expect(taskBasis(fromProblem), t.tasks.basisProblem(number: 'ПБ-000009'));
    expect(
      supplierBasis('', problem: fromProblem.problem),
      t.tasks.fromProblem(number: 'ПБ-000009'),
    );
  });

  test('пересчёт - сам пересчёт, а не «приёмка от <дата>» (ADHOC-58)', () {
    final stocktake = {
      'number': 12,
      'scope_kind': 'all',
      'created_by': 'Сергей Семёнов',
      'cells': 4,
      'counted': 4,
    };
    final task = WarehouseTask.fromJson({
      'id': 't3',
      'number': 3,
      'kind': TaskKind.stocktake,
      'status': TaskStatus.done,
      'warehouse_id': 'w1',
      'receipt_id': null,
      'supplier': '',
      'created_at': '2026-11-05T08:44:00Z',
      'stocktake_id': 's1',
      'stocktake': stocktake,
    });
    final line = t.tasks.stocktakeLine(
      number: docNumber(DocKind.stocktake, 12),
    );
    expect(taskBasis(task), line);

    final completed = CompletedTask.fromJson({
      'id': 't3',
      'number': 3,
      'kind': TaskKind.stocktake,
      'supplier': '',
      'completed_at': '2026-11-05T08:45:00Z',
      'sessions': 4,
      'stocktake': stocktake,
    });
    expect(
      supplierBasis(
        completed.supplier,
        kind: completed.kind,
        stocktake: completed.stocktake,
      ),
      line,
    );
  });

  test('подсчёт ячейки в журнале задания - адрес ячейки (ADHOC-58)', () {
    final ev = TaskEvent.fromJson({
      'event': 'cell_counted',
      'user': 'Кладовщик',
      'cell': 'M1-1-1-1',
      'at': '2026-11-05T08:45:00Z',
    });
    expect(ev.event, TaskEventKind.cellCounted);
    expect(ev.cell, 'M1-1-1-1');
  });
}
