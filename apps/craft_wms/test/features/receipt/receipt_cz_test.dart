import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/features/cz/domain/cz_intake.dart';
import 'package:craft_wms/features/cz/domain/cz_scan.dart';
import 'package:craft_wms/features/receipt/data/receipt_draft_store.dart';
import 'package:craft_wms/features/receipt/data/receipt_repository.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_cubit.dart';
import 'package:craft_wms/features/receipt/presentation/bloc/receipt_models.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockCatalog extends Mock implements CatalogRepository {}

class _MockRepo extends Mock implements ReceiptRepository {}

class _MockPrinter extends Mock implements PrinterService {}

/// Приёмка марок «Честного знака» на ТСД (CZ-05): из ответа скана в строки, короб ЧЗ, марки
/// россыпью, повторы, черновик.
void main() {
  const beer = Good(id: 'g1', name: 'Пиво', uom: 'шт', czMarked: true);
  const gtin = '04612728200172';
  const box = '00146127282000000172';
  const pack = '0114612728200179215G1';
  String mark(String n) => '0104612728200172215$n';
  const defaultCell = Cell(
    id: 'c-def',
    warehouseId: 'w1',
    address: 'С-Н-П',
    isDefault: true,
  );
  const cell1 = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');
  const doc = ReceiptDoc(number: 'ТН-1', date: '01.10.2026');

  late AppDatabase db;
  late ReceiptCubit cubit;
  late _MockCatalog catalog;

  ReceiptCubit newCubit() => ReceiptCubit(
    catalog,
    _MockRepo(),
    ReceiptDraftStore(db),
    const LoadUnitIdGenerator(Uuid()),
    _MockPrinter(),
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    catalog = _MockCatalog();
    when(
      () => catalog.defaultCell(),
    ).thenAnswer((_) async => const Right(defaultCell));
    cubit = newCubit();
    await cubit.start(null, doc);
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  // Короб ЧЗ: упаковка с двумя марками, одна марка прямо в коробе, другая партия - чужая.
  final boxScan = CzScanResult(
    code: box,
    kind: CzCodeKind.box,
    composition: [
      CzCompositionLine(
        gtin: gtin,
        productName: 'Пиво по ЧЗ',
        producedDate: DateTime(2026, 9, 1),
        count: 3,
        cis: [mark('M1'), mark('M2'), mark('M3')],
      ),
      CzCompositionLine(
        gtin: gtin,
        productName: 'Пиво по ЧЗ',
        producedDate: DateTime(2026, 9, 2),
        count: 1,
        cis: [mark('M4')],
        discrepancy: 'foreign_mark',
      ),
    ],
    units: 4,
    groups: const [CzGroupRef(code: pack, parentCode: box)],
    parents: {
      mark('M1'): pack,
      mark('M2'): pack,
      mark('M3'): box,
      mark('M4'): box,
    },
  );

  group('из ответа скана', () {
    test('состав короба - строки по партии, упаковка каждой марки', () {
      final lines = czIntakeLines(boxScan, {gtin: beer});
      expect(lines.map((l) => l.date), ['01.09.2026', '02.09.2026']);
      expect(lines.first.marks.map((m) => m.aggregateCode), [pack, pack, box]);
      expect(lines.last.marks.single.discrepancy, 'foreign_mark');
      expect(czIntakeGroups(boxScan), const [
        CzGroupDraft(code: pack, parentCode: box),
      ]);
    });

    test('марка - одна единица россыпью, без упаковки', () {
      final scan = CzScanResult(
        code: mark('U1'),
        kind: CzCodeKind.unit,
        gtin: gtin,
        producedDate: DateTime(2026, 9, 1),
        discrepancy: 'retired',
      );
      final line = czIntakeLines(scan, {gtin: beer}).single;
      expect(
        line.marks.single,
        CzMarkDraft(cis: mark('U1'), discrepancy: 'retired'),
      );
      expect(czIntakeGroups(scan), isEmpty);
    });

    test('чего не хватает: незнакомый GTIN и единицы без даты', () {
      final gaps = czScanGaps(
        CzScanResult(code: mark('U1'), kind: CzCodeKind.unit, gtin: gtin),
        const {},
      );
      expect(gaps.unknownGtins, [gtin]);
      expect(gaps.noDate, isTrue);
      expect(ean13FromGtin(gtin), '4612728200172');
    });
  });

  group('приёмка', () {
    test('короб ЧЗ - новая ГЕ в текущей ячейке, повтор кода - отказ', () {
      cubit.setTargetCell(cell1);
      final r = cubit.addCzBox(
        code: box,
        lines: czIntakeLines(boxScan, {gtin: beer}),
        groups: czIntakeGroups(boxScan),
      );
      expect(r.result, CzIntakeAdd.added);
      final b = cubit.state.boxById(r.boxId!)!;
      expect(b.czCode, box);
      expect(b.cell, cell1);
      expect(b.shortCode, '0000 0172');
      expect(cubit.state.linesOf(b.id).map((l) => l.qty), [3, 1]);
      expect(cubit.state.lines.last.discrepancies, 1);

      expect(
        cubit.addCzBox(code: box, lines: const [], groups: const []).result,
        CzIntakeAdd.duplicate,
      );
    });

    test('в короб ЧЗ не добавляют ни марки, ни товар по ШК', () async {
      final r = cubit.addCzBox(
        code: box,
        lines: czIntakeLines(boxScan, {gtin: beer}),
      );
      final single = [
        CzIntakeLine(
          good: beer,
          date: '01.09.2026',
          marks: [CzMarkDraft(cis: mark('X1'))],
        ),
      ];
      expect(
        cubit.addCzMarks(lines: single, boxId: r.boxId),
        CzIntakeAdd.czBoxClosed,
      );
      const plain = Good(id: 'g2', name: 'Кальмар', uom: 'шт');
      await cubit.addLine(
        good: plain,
        date: '01.09.2026',
        qty: 1,
        boxId: r.boxId,
      );
      expect(cubit.state.linesOf(r.boxId!).length, 2);
    });

    test('марки россыпью копятся в строке партии, повтор марки - отказ', () {
      CzIntakeLine one(String n) => CzIntakeLine(
        good: beer,
        date: '01.09.2026',
        marks: [CzMarkDraft(cis: mark(n))],
      );
      expect(cubit.addCzMarks(lines: [one('A')]), CzIntakeAdd.added);
      expect(cubit.addCzMarks(lines: [one('B')]), CzIntakeAdd.added);
      expect(cubit.addCzMarks(lines: [one('A')]), CzIntakeAdd.duplicate);
      final line = cubit.state.lines.single;
      expect(line.qty, 2);
      expect(line.marks.map((m) => m.cis), [mark('A'), mark('B')]);
    });

    test('удалённый короб ЧЗ уносит свои упаковки', () {
      final r = cubit.addCzBox(
        code: box,
        lines: czIntakeLines(boxScan, {gtin: beer}),
        groups: czIntakeGroups(boxScan),
      );
      cubit.removeBox(r.boxId!);
      expect(cubit.state.lines, isEmpty);
      expect(cubit.state.czGroups, isEmpty);
    });

    test('короб ЧЗ, марки и упаковки переживают перезапуск', () async {
      cubit.addCzBox(
        code: box,
        lines: czIntakeLines(boxScan, {gtin: beer}),
        groups: czIntakeGroups(boxScan),
      );
      await cubit.draftWrites;

      final restored = newCubit();
      addTearDown(restored.close);
      await restored.restore();
      expect(restored.state.boxes.single.czCode, box);
      expect(restored.state.czGroups, cubit.state.czGroups);
      expect(restored.state.lines, cubit.state.lines);
    });
  });
}
