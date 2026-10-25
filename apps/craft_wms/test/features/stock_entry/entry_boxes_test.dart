import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/features/cz/domain/cz_intake.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockRepo extends Mock implements StockEntryRepository {}

class _MockCatalog extends Mock implements CatalogRepository {}

class _MockPrinter extends Mock implements PrinterService {}

/// Короба и марки ЧЗ в ячейке прохода (ADHOC-46): грань строки с коробом, закрытый короб ЧЗ,
/// повторы марок и коробов по всему проходу, отмена, смена ячейки, слепок, финал с марками.
void main() {
  const lemon = Good(id: 'gL', name: 'Лимонад', uom: 'шт');
  const beer = Good(id: 'gB', name: 'Пиво', uom: 'шт', czMarked: true);
  const cell1 = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');
  const cell2 = Cell(id: 'c2', warehouseId: 'w1', address: 'M1-1-1-2');
  const sscc = '00146127282000000172';

  late _MockRepo repo;
  late AppDatabase db;
  late EntryDraftStore drafts;
  late StockEntryCubit cubit;

  StockEntryCubit newCubit() => StockEntryCubit(
    repo,
    _MockCatalog(),
    drafts,
    const LoadUnitIdGenerator(Uuid()),
    _MockPrinter(),
  );

  CzIntakeLine beerMarks(String date, List<String> cis, {String? box}) =>
      CzIntakeLine(
        good: beer,
        date: date,
        marks: [for (final c in cis) CzMarkDraft(cis: c, aggregateCode: box)],
      );

  setUp(() {
    repo = _MockRepo();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = EntryDraftStore(db);
    cubit = newCubit();
    cubit.selectCell(cell1);
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  test('строка в коробе и россыпью — разные грани', () async {
    final box = cubit.newBox();
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 4);
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 6, boxId: box);
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 1, boxId: box);

    expect(cubit.state.looseLines.single.qty, 4);
    expect(cubit.state.linesOf(box).single.qty, 7);
  });

  test('в короб ЧЗ руками не кладут', () async {
    final box = cubit
        .addCzBox(
          code: sscc,
          lines: [
            beerMarks('01.09.2026', ['m1']),
          ],
        )
        .boxId!;
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 1, boxId: box);
    expect(
      cubit.addCzMarks(
        lines: [
          beerMarks('01.09.2026', ['m2']),
        ],
        boxId: box,
      ),
      CzIntakeAdd.czBoxClosed,
    );
    expect(cubit.state.linesOf(box).single.good.id, 'gB');
  });

  test('короб ЧЗ и марка — один раз на весь проход', () {
    cubit.addCzBox(
      code: sscc,
      lines: [
        beerMarks('01.09.2026', ['m1']),
      ],
    );
    cubit.finishCell();
    cubit.selectCell(cell2);

    expect(
      cubit
          .addCzBox(
            code: sscc,
            lines: [
              beerMarks('01.09.2026', ['m9']),
            ],
          )
          .result,
      CzIntakeAdd.duplicate,
    );
    expect(
      cubit.addCzMarks(
        lines: [
          beerMarks('01.09.2026', ['m1']),
        ],
      ),
      CzIntakeAdd.duplicate,
    );
    expect(cubit.state.lines, isEmpty);
  });

  test('удаление короба ЧЗ уносит строки и упаковки, отмена возвращает', () {
    final box = cubit
        .addCzBox(
          code: sscc,
          lines: [
            beerMarks('01.09.2026', ['m1', 'm2'], box: 'grp'),
          ],
          groups: const [CzGroupDraft(code: 'grp', parentCode: sscc)],
        )
        .boxId!;
    cubit.removeBox(box);
    expect(cubit.state.boxes, isEmpty);
    expect(cubit.state.lines, isEmpty);
    expect(cubit.state.czGroups, isEmpty);

    cubit.undo();
    expect(cubit.state.boxById(box)?.czCode, sscc);
    expect(cubit.state.linesOf(box).single.marks, hasLength(2));
    expect(cubit.state.czGroups.single.code, 'grp');
  });

  test('строку с марками не правят', () {
    cubit.addCzMarks(
      lines: [
        beerMarks('01.09.2026', ['m1']),
      ],
    );
    cubit.editLine(cubit.state.lines.single, date: '02.09.2026', qty: 5);
    expect(cubit.state.lines.single.qty, 1);
    expect(cubit.state.lines.single.productionDate, '01.09.2026');
  });

  test('пустой короб в пройденную ячейку не попадает', () async {
    final used = cubit.newBox();
    cubit.newBox(); // ярлык напечатали, товар не положили
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 2, boxId: used);
    cubit.finishCell();
    expect(cubit.state.committedCells.single.boxes.single.id, used);
  });

  test('смена ячейки везёт короба и сливается с пройденной', () async {
    cubit.selectCell(cell2);
    final box2 = cubit.newBox();
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 3, boxId: box2);
    cubit.finishCell();

    cubit.selectCell(cell1);
    final box1 = cubit.newBox();
    await cubit.addLine(good: lemon, date: '15.08.2026', qty: 5, boxId: box1);
    cubit.changeCell(cell2);

    expect(cubit.state.cell?.id, 'c2');
    expect(cubit.state.boxes.map((b) => b.id), containsAll([box1, box2]));
    expect(cubit.state.committedCells, isEmpty);
  });

  test('слепок прохода хранит короба, марки и упаковки', () async {
    final box = cubit
        .addCzBox(
          code: sscc,
          lines: [
            beerMarks('01.09.2026', ['m1'], box: sscc),
          ],
          groups: const [CzGroupDraft(code: 'grp', parentCode: sscc)],
        )
        .boxId!;
    await cubit.draftWrites;

    final restored = newCubit();
    addTearDown(restored.close);
    await restored.restore();
    expect(restored.state.boxById(box)?.czCode, sscc);
    expect(restored.state.lines.single.marks.single.aggregateCode, sscc);
    expect(restored.state.czGroups.single.code, 'grp');
  });

  test('проход с марками не завершается, пока очередь не ушла', () async {
    when(() => repo.drainQueue()).thenAnswer((_) async => false);
    cubit.addCzMarks(
      lines: [
        beerMarks('01.09.2026', ['m1']),
      ],
    );
    cubit.finishCell();

    await cubit.finishSession();

    expect(cubit.state.failure, const Failure.unknown(kQueuePending));
    expect(cubit.state.busy, isFalse);
    verifyNever(() => repo.startSession(any()));
  });
}
