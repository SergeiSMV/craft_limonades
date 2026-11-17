import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockPrinter extends Mock implements PrinterService {}

class _MockRepo extends Mock implements StockEntryRepository {}

class _MockCatalog extends Mock implements CatalogRepository {}

void main() {
  const goodA = Good(id: 'gA', name: 'Товар A', uom: 'шт');
  const goodB = Good(id: 'gB', name: 'Товар B', uom: 'кг');
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  late _MockRepo repo;
  late _MockCatalog catalog;
  late AppDatabase db;
  late EntryDraftStore drafts;
  late StockEntryCubit cubit;

  setUp(() {
    repo = _MockRepo();
    catalog = _MockCatalog();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = EntryDraftStore(db);
    cubit = StockEntryCubit(
      repo,
      catalog,
      drafts,
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    // Привязка уходит операцией очереди (ADHOC-14) - репозиторий её принимает всегда.
    when(
      () => catalog.bindBarcode(
        goodId: any(named: 'goodId'),
        barcode: any(named: 'barcode'),
      ),
    ).thenAnswer((_) async => const Right(null));
    when(() => catalog.cancelPendingBind(any())).thenAnswer((_) async => true);
  });

  tearDown(() => db.close());

  group('буфер: грань (товар, дата) + undo', () {
    test('та же дата → накопление; другая дата → новая строка', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 5);
      expect(cubit.state.lines.length, 1);
      expect(cubit.state.lines.first.qty, 15);

      // Тот же товар, ДРУГАЯ партия → отдельная строка (ключевое требование P-FS-07).
      cubit.addLine(good: goodA, date: '20.02.2026', qty: 3);
      expect(cubit.state.lines.length, 2);

      cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);
      expect(cubit.state.lines.length, 3);
    });

    test('undo восстанавливает предыдущий буфер целиком', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);
      expect(cubit.state.lines.length, 2);

      cubit.undo();
      expect(cubit.state.lines.length, 1);
      expect(cubit.state.lines.first.good.id, 'gA');
      expect(cubit.state.lines.first.qty, 10);
    });

    // Привязка больше не копится в состоянии прохода, а уходит обычной операцией очереди
    // (ADHOC-14). Оттуда она сразу попадает в кэш с пометкой «ожидает», и повторный скан
    // резолвится тем же кэш-first путём, что и везде, - своей дороги у прохода не осталось.
    test('новый ШК уходит операцией очереди', () async {
      await cubit.addLine(
        good: goodA,
        date: '15.01.2026',
        qty: 10,
        newBarcode: '460',
        symbology: '',
      );

      verify(() => catalog.bindBarcode(goodId: 'gA', barcode: '460')).called(1);
    });

    test('строка без нового ШК привязку не создаёт', () async {
      await cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);

      verifyNever(
        () => catalog.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      );
    });

    test(
      'несколько разных ШК на один товар - все узнаются (штука + короб)',
      () async {
        // Штучный ШК и ШК короба ведут на один товar, одна партия - обе привязки должны жить.
        await cubit.addLine(
          good: goodA,
          date: '15.01.2026',
          qty: 10,
          newBarcode: 'ITEM',
          symbology: '',
        );
        await cubit.addLine(
          good: goodA,
          date: '15.01.2026',
          qty: 120,
          newBarcode: 'BOX',
          symbology: '',
        );
        expect(
          cubit.state.lines.length,
          1,
        ); // грань (товар,дата) одна → строки слились: 10+120
        expect(cubit.state.lines.single.qty, 130);
        // Обе привязки уцелели - старая модель второй ШК теряла (P-FS-11). Теперь это две
        // независимые операции очереди, и слияние строк на них не влияет.
        verify(
          () => catalog.bindBarcode(goodId: 'gA', barcode: 'ITEM'),
        ).called(1);
        verify(
          () => catalog.bindBarcode(goodId: 'gA', barcode: 'BOX'),
        ).called(1);
      },
    );

    test('undo снимает привязку шага, пока та не ушла', () async {
      await cubit.addLine(
        good: goodA,
        date: '15.01.2026',
        qty: 10,
        newBarcode: 'ITEM',
        symbology: '',
      );
      await cubit.addLine(
        good: goodA,
        date: '15.01.2026',
        qty: 120,
        newBarcode: 'BOX',
        symbology: '',
      );
      await cubit.undo(); // отменить привязку BOX

      // Отменяем только то, что ещё не ушло (решение пользователя, ADHOC-14): cubit просит
      // снять операцию из очереди. Ушедшую отзывать нечем - её убирают «неверным товаром».
      verify(() => catalog.cancelPendingBind('BOX')).called(1);
      verifyNever(() => catalog.cancelPendingBind('ITEM'));
      expect(cubit.state.lines.single.qty, 10);
    });

    // «Неверный товар» (P-FS-12): успели снять из очереди - отвязку не шлём, она бессмысленна.
    test('неверный товар: неушедшую привязку снимаем из очереди', () async {
      when(
        () => catalog.cancelPendingBind('ITEM'),
      ).thenAnswer((_) async => true);

      await cubit.removeBarcode('ITEM', goodId: 'gA');

      verify(() => catalog.cancelPendingBind('ITEM')).called(1);
      verifyNever(
        () => catalog.unbindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      );
    });

    // Не успели - код уже на сервере или в пути, убрать его можно только отвязкой.
    test('неверный товар: ушедшую привязку отвязываем', () async {
      when(
        () => catalog.cancelPendingBind('ITEM'),
      ).thenAnswer((_) async => false);
      when(
        () => catalog.unbindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Right(null));

      await cubit.removeBarcode('ITEM', goodId: 'gA');

      verify(
        () => catalog.unbindBarcode(goodId: 'gA', barcode: 'ITEM'),
      ).called(1);
    });

    test('removeLine удаляет строку (по грани) и кладёт снимок в undo', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);
      final target = cubit.state.lines.first; // goodA
      cubit.removeLine(target);
      expect(cubit.state.lines.length, 1);
      expect(cubit.state.lines.single.good.id, 'gB');
      cubit.undo(); // возврат удалённой
      expect(cubit.state.lines.length, 2);
    });

    test('editLine заменяет дату/количество строки', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      final target = cubit.state.lines.single;
      cubit.editLine(target, date: '20.02.2026', qty: 7);
      expect(cubit.state.lines.length, 1);
      expect(cubit.state.lines.single.productionDate, '20.02.2026');
      expect(cubit.state.lines.single.qty, 7);
    });

    test('editLine на существующую партию сливает количества', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodA, date: '20.02.2026', qty: 3);
      final target = cubit.state.lines.last; // (gA, 20.02) = 3
      // Меняем дату на 15.01 → совпала с первой строкой → слить: 10 + 3 = 13, одна строка.
      cubit.editLine(target, date: '15.01.2026', qty: 3);
      expect(cubit.state.lines.length, 1);
      expect(cubit.state.lines.single.productionDate, '15.01.2026');
      expect(cubit.state.lines.single.qty, 13);
    });

    test('глубина undo ограничена kUndoDepth', () {
      for (var i = 0; i < 15; i++) {
        cubit.addLine(good: goodA, date: '0$i.01.2026', qty: 1);
      }
      expect(cubit.state.undoStack.length, kUndoDepth);
    });
  });

  group('пройденные ячейки (локально) и финал', () {
    const cell2 = Cell(id: 'c2', warehouseId: 'w1', address: 'M1-1-1-2');

    test(
      'selectCell не ходит в сеть; finishCell локально складывает ячейку',
      () {
        cubit.selectCell(cell); // без сети
        cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
        cubit.finishCell();

        expect(cubit.state.cell, isNull);
        expect(cubit.state.lines, isEmpty);
        expect(cubit.state.committedCells.length, 1);
        expect(cubit.state.committedCells.single.cell.id, 'c1');
        verifyNever(() => repo.startSession(any()));
        verifyNever(
          () => repo.checkpoint(
            sessionId: any(named: 'sessionId'),
            body: any(named: 'body'),
          ),
        );
      },
    );

    test('пустую ячейку не добавляем', () {
      cubit.selectCell(cell);
      cubit.finishCell(); // строк нет
      expect(cubit.state.committedCells, isEmpty);
    });

    test('selectCell пройденной ячейки открывает её на редактирование', () {
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.finishCell();

      cubit.selectCell(cell); // повторно ту же
      expect(cubit.state.cell?.id, 'c1');
      expect(cubit.state.lines.length, 1); // строки вернулись в буфер
      expect(cubit.state.committedCells, isEmpty); // и убраны из пройденных
    });

    test('removeCommittedCell удаляет ячейку из списка', () {
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.finishCell();
      cubit.removeCommittedCell('c1');
      expect(cubit.state.committedCells, isEmpty);
    });

    test(
      'changeCell перецеливает буфер на новую ячейку, строки сохраняются',
      () {
        cubit.selectCell(cell); // c1
        cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
        cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);

        cubit.changeCell(cell2); // не та ячейка → c2, товары те же
        expect(cubit.state.cell?.id, 'c2');
        expect(cubit.state.lines.length, 2); // строки не тронуты
        expect(cubit.state.committedCells, isEmpty);
      },
    );

    test('changeCell на уже пройденную ячейку сливает количества по грани', () {
      // Ячейка c2 уже пройдена: goodA 15.01 = 5.
      cubit.selectCell(cell2);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 5);
      cubit.finishCell();
      // Работаем в c1: goodA 15.01 = 10 (та же грань) + goodB.
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);

      cubit.changeCell(cell2); // сливаем с пройденной c2
      expect(cubit.state.cell?.id, 'c2');
      expect(cubit.state.committedCells, isEmpty); // c2 вынута из пройденных
      // goodA 15.01: 10 + 5 = 15 (слито по грани); goodB - отдельно.
      final ga = cubit.state.lines.firstWhere(
        (l) => l.good.id == 'gA' && l.productionDate == '15.01.2026',
      );
      expect(ga.qty, 15);
      expect(cubit.state.lines.length, 2);
    });

    test('changeCell на ту же ячейку - no-op', () {
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.changeCell(cell); // та же
      expect(cubit.state.cell?.id, 'c1');
      expect(cubit.state.lines.length, 1);
    });

    test(
      'finishSession: старт → checkpoint каждой ячейки → финал; даты в DD-MM-YYYY',
      () async {
        when(
          () => repo.startSession('w1'),
        ).thenAnswer((_) async => const Right('sess-1'));
        when(
          () => repo.checkpoint(
            sessionId: any(named: 'sessionId'),
            body: any(named: 'body'),
          ),
        ).thenAnswer((_) async => const Right(null));
        when(
          () => repo.finalize('sess-1'),
        ).thenAnswer((_) async => const Right(3));

        // Ячейка 1: два товара; goodA с двумя разными ШК (штука + короб), goodB с ещё одним ШК.
        cubit.selectCell(cell);
        await cubit.addLine(
          good: goodA,
          date: '15.01.2026',
          qty: 10,
          newBarcode: '460',
          symbology: '',
        );
        cubit.addLine(
          good: goodA,
          date: '15.01.2026',
          qty: 1,
          newBarcode: 'BOX460',
        );
        cubit.addLine(
          good: goodB,
          date: '20.02.2026',
          qty: 2,
          newBarcode: '777',
        );
        cubit.finishCell();
        // Ячейка 2 - товар без нового ШК.
        cubit.selectCell(cell2);
        cubit.addLine(good: goodA, date: '15.01.2026', qty: 5);
        cubit.finishCell();

        expect(cubit.state.canFinishSession, isTrue);
        await cubit.finishSession();

        verify(() => repo.startSession('w1')).called(1);
        // Checkpoint по каждой ячейке.
        final captured = verify(
          () => repo.checkpoint(
            sessionId: captureAny(named: 'sessionId'),
            body: captureAny(named: 'body'),
          ),
        ).captured;
        // captured - плоский список по 2 на вызов (сессия, тело); 2 вызова = 4 элемента.
        expect(captured.length, 4);
        expect(captured[0], 'sess-1'); // ячейка 1
        final body1 = captured[1] as Map<String, dynamic>;
        expect(body1['cell_id'], 'c1');
        final lines1 = body1['lines'] as List;
        expect(lines1.length, 2); // (gA,15.01) + (gB,20.02)
        // Привязки с checkpoint'ом больше не едут (ADHOC-14): они ушли своими операциями
        // очереди. Прежде вся копилка везлась с ПЕРВЫМ checkpoint, и один конфликтный ШК
        // откатывал вместе с собой просчёт целой ячейки.
        expect(body1['new_barcodes'] as List, isEmpty);
        verify(
          () => catalog.bindBarcode(goodId: 'gA', barcode: '460'),
        ).called(1);
        verify(
          () => catalog.bindBarcode(goodId: 'gA', barcode: 'BOX460'),
        ).called(1);
        verify(
          () => catalog.bindBarcode(goodId: 'gB', barcode: '777'),
        ).called(1);
        expect((lines1.first as Map)['production_date'], '15-01-2026');
        final body2 = captured[3] as Map<String, dynamic>;
        expect(body2['cell_id'], 'c2'); // ячейка 2
        expect(body2['new_barcodes'] as List, isEmpty);
        // Проход без марок очередь перед финалом не ждёт.
        verifyNever(() => repo.drainQueue());

        verify(() => repo.finalize('sess-1')).called(1);
        expect(cubit.state.finished, isTrue);
        expect(cubit.state.written, 3);
      },
    );
  });
}
