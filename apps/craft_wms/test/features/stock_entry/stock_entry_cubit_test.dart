import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock_entry/data/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements StockEntryRepository {}

void main() {
  const goodA = Good(id: 'gA', name: 'Товар A', uom: 'шт');
  const goodB = Good(id: 'gB', name: 'Товар B', uom: 'кг');
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  late _MockRepo repo;
  late StockEntryCubit cubit;

  setUp(() {
    repo = _MockRepo();
    cubit = StockEntryCubit(repo);
  });

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

    test('localGoodForBarcode находит товар среди привязок прохода', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10, newBarcode: '460', symbology: '');
      // Повторный скан того же ШК (для другой партии) должен резолвиться локально, без сервера.
      expect(cubit.localGoodForBarcode('460')?.id, 'gA');
      expect(cubit.localGoodForBarcode('999'), isNull);
    });

    test('несколько разных ШК на один товар — все узнаются (штука + короб)', () {
      // Штучный ШК и ШК короба ведут на один товar, одна партия — обе привязки должны жить.
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10, newBarcode: 'ITEM', symbology: '');
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 120, newBarcode: 'BOX', symbology: '');
      expect(cubit.state.lines.length, 1); // грань (товар,дата) одна → строки слились: 10+120
      expect(cubit.state.lines.single.qty, 130);
      // Но обе привязки уцелели — старая модель второй ШК теряла.
      expect(cubit.localGoodForBarcode('ITEM')?.id, 'gA');
      expect(cubit.localGoodForBarcode('BOX')?.id, 'gA');
      expect(cubit.state.barcodes.length, 2);
    });

    test('undo откатывает и привязку ШК, не только количество', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10, newBarcode: 'ITEM', symbology: '');
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 120, newBarcode: 'BOX', symbology: '');
      cubit.undo(); // отменить привязку BOX
      expect(cubit.localGoodForBarcode('BOX'), isNull);
      expect(cubit.localGoodForBarcode('ITEM')?.id, 'gA'); // первая осталась
      expect(cubit.state.lines.single.qty, 10);
    });

    test('removeLocalBarcode убирает привязку из копилки; undo возвращает', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10, newBarcode: 'ITEM', symbology: '');
      expect(cubit.localGoodForBarcode('ITEM')?.id, 'gA');
      cubit.removeLocalBarcode('ITEM');
      expect(cubit.localGoodForBarcode('ITEM'), isNull); // отвязано локально
      expect(cubit.state.lines.single.qty, 10); // строка не тронута
      cubit.undo();
      expect(cubit.localGoodForBarcode('ITEM')?.id, 'gA'); // вернулось
    });

    test('removeLocalBarcode для отсутствующего ШК — no-op (не плодит undo)', () {
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      final undoBefore = cubit.state.undoStack.length;
      cubit.removeLocalBarcode('НЕТ_ТАКОГО');
      expect(cubit.state.undoStack.length, undoBefore);
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

    test('selectCell не ходит в сеть; finishCell локально складывает ячейку', () {
      cubit.selectCell(cell); // без сети
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.finishCell();

      expect(cubit.state.cell, isNull);
      expect(cubit.state.lines, isEmpty);
      expect(cubit.state.committedCells.length, 1);
      expect(cubit.state.committedCells.single.cell.id, 'c1');
      verifyNever(() => repo.startSession(any()));
      verifyNever(() => repo.checkpoint(
            sessionId: any(named: 'sessionId'),
            cellId: any(named: 'cellId'),
            lines: any(named: 'lines'),
            newBarcodes: any(named: 'newBarcodes'),
          ));
    });

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

    test('changeCell перецеливает буфер на новую ячейку, строки сохраняются', () {
      cubit.selectCell(cell); // c1
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.addLine(good: goodB, date: '15.01.2026', qty: 2);

      cubit.changeCell(cell2); // не та ячейка → c2, товары те же
      expect(cubit.state.cell?.id, 'c2');
      expect(cubit.state.lines.length, 2); // строки не тронуты
      expect(cubit.state.committedCells, isEmpty);
    });

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
      // goodA 15.01: 10 + 5 = 15 (слито по грани); goodB — отдельно.
      final ga = cubit.state.lines
          .firstWhere((l) => l.good.id == 'gA' && l.productionDate == '15.01.2026');
      expect(ga.qty, 15);
      expect(cubit.state.lines.length, 2);
    });

    test('changeCell на ту же ячейку — no-op', () {
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      cubit.changeCell(cell); // та же
      expect(cubit.state.cell?.id, 'c1');
      expect(cubit.state.lines.length, 1);
    });

    test('finishSession: старт → checkpoint каждой ячейки → финал; даты в DD-MM-YYYY', () async {
      when(() => repo.startSession('w1')).thenAnswer((_) async => const Right('sess-1'));
      when(() => repo.checkpoint(
            sessionId: any(named: 'sessionId'),
            cellId: any(named: 'cellId'),
            lines: any(named: 'lines'),
            newBarcodes: any(named: 'newBarcodes'),
          )).thenAnswer((_) async => const Right(null));
      when(() => repo.finalize('sess-1')).thenAnswer((_) async => const Right(3));

      // Ячейка 1: два товара; goodA с двумя разными ШК (штука + короб), goodB с ещё одним ШК.
      cubit.selectCell(cell);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10, newBarcode: '460', symbology: '');
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 1, newBarcode: 'BOX460');
      cubit.addLine(good: goodB, date: '20.02.2026', qty: 2, newBarcode: '777');
      cubit.finishCell();
      // Ячейка 2 — товар без нового ШК.
      cubit.selectCell(cell2);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 5);
      cubit.finishCell();

      expect(cubit.state.canFinishSession, isTrue);
      await cubit.finishSession();

      verify(() => repo.startSession('w1')).called(1);
      // Checkpoint по каждой ячейке.
      final captured = verify(() => repo.checkpoint(
            sessionId: captureAny(named: 'sessionId'),
            cellId: captureAny(named: 'cellId'),
            lines: captureAny(named: 'lines'),
            newBarcodes: captureAny(named: 'newBarcodes'),
          )).captured;
      // captured — плоский список по 4 на вызов; 2 вызова = 8 элементов.
      expect(captured.length, 8);
      expect(captured[0], 'sess-1'); // ячейка 1
      expect(captured[1], 'c1');
      final lines1 = captured[2] as List;
      expect(lines1.length, 2); // (gA,15.01) + (gB,20.02)
      // Вся копилка ШК (три разных: 460, BOX460, 777) уходит с ПЕРВЫМ checkpoint.
      final barcodes1 = captured[3] as List;
      expect(barcodes1.length, 3);
      expect(barcodes1.map((b) => (b as Map)['barcode']).toSet(), {'460', 'BOX460', '777'});
      expect((lines1.first as Map)['production_date'], '15-01-2026');
      expect(captured[5], 'c2'); // ячейка 2
      expect((captured[7] as List), isEmpty); // ШК уже отправлены с первой ячейкой

      verify(() => repo.finalize('sess-1')).called(1);
      expect(cubit.state.finished, isTrue);
      expect(cubit.state.written, 3);
    });
  });
}
