import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:craft_wms/features/tasks/presentation/widgets/common/task_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Основание задания (ADHOC-23): документ поставщика, а у заданий до ADHOC-23 — приёмка по дате.
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

  test('с документом — номер и дата документа', () {
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

  test('без документа (до ADHOC-23) — приёмка по дате оприходования', () {
    expect(
      taskBasis(task()),
      t.tasks.basisReceipt(date: '05.10.2026', supplier: 'ИП Березин'),
    );
  });
}
