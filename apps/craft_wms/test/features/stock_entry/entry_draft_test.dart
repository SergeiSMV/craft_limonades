import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock/domain/catalog_repository.dart';
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

/// Durability прохода «Ввода остатков» (P2-03).
///
/// Проход копится в памяти и уходит на сервер одним махом на финале (вариант A), поэтому
/// падение приложения, разряд батареи или выгрузка процесса Android'ом теряли **весь** обход
/// склада - сотни ячеек и часы работы, при исправной сети.
void main() {
  const goodA = Good(id: 'gA', name: 'Товар A', uom: 'шт');
  const cellA = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');
  const cellB = Cell(id: 'c2', warehouseId: 'w1', address: 'M1-1-1-2');

  late AppDatabase db;
  late EntryDraftStore drafts;
  late _MockRepo repo;
  late StockEntryCubit cubit;
  late _MockCatalog catalog;

  setUp(() {
    catalog = _MockCatalog();
    // Привязка уходит операцией очереди (ADHOC-14) - репозиторий её принимает.
    when(
      () => catalog.bindBarcode(
        goodId: any(named: 'goodId'),
        barcode: any(named: 'barcode'),
      ),
    ).thenAnswer((_) async => const Right(null));
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = EntryDraftStore(db);
    repo = _MockRepo();
    cubit = StockEntryCubit(
      repo,
      catalog,
      drafts,
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
  });

  tearDown(() => db.close());

  test('пустой проход слепка не оставляет', () async {
    await cubit.draftWrites;

    expect(await drafts.load(), isNull);
  });

  test('строки и пройденные ячейки попадают в слепок', () async {
    cubit.selectCell(cellA);
    cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
    cubit.finishCell();
    await cubit.draftWrites;

    final draft = await drafts.load();
    expect(draft, isNotNull);
    expect(draft!['committed_cells'], hasLength(1));
    expect(draft['cell'], isNull, reason: 'ячейка завершена, текущей нет');
  });

  test('восстановление возвращает буфер текущей ячейки', () async {
    cubit.selectCell(cellA);
    await cubit.addLine(
      good: goodA,
      date: '15.01.2026',
      qty: 7,
      newBarcode: '4607044662964',
      symbology: 'Code128',
    );
    await cubit.draftWrites;

    // Новый cubit поверх того же хранилища - как после перезапуска экрана.
    final restored = StockEntryCubit(
      repo,
      catalog,
      drafts,
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    await restored.restore();

    expect(restored.state.cell?.id, cellA.id);
    expect(restored.state.lines, hasLength(1));
    expect(restored.state.lines.single.qty, 7);
    expect(restored.state.lines.single.good.id, goodA.id);
    expect(
      restored.state.undoStack,
      isEmpty,
      reason: 'Undo служит текущему действию и переживать перезапуск не должен',
    );
    await restored.close();
  });

  test('финал убирает слепок: восстанавливать нечего', () async {
    when(
      () => repo.startSession(any()),
    ).thenAnswer((_) async => const Right('s1'));
    when(
      () => repo.checkpoint(
        sessionId: any(named: 'sessionId'),
        body: any(named: 'body'),
      ),
    ).thenAnswer((_) async => const Right(null));
    when(() => repo.finalize(any())).thenAnswer((_) async => const Right(1));

    cubit.selectCell(cellA);
    cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
    cubit.finishCell();
    await cubit.finishSession();
    await cubit.draftWrites;

    expect(cubit.state.finished, isTrue);
    expect(await drafts.load(), isNull);
  });

  // Выход с экрана проход НЕ трогает (ADHOC-13). Прежде «назад» на непустом проходе показывал
  // диалог «просчитанные ячейки не сохранены и будут потеряны» и стирал слепок - текст был
  // неправдой с момента P2-03, а действие уничтожало единственную копию работы кладовщика
  // за обычное нажатие навигации.
  test('проход переживает уход с экрана и поднимается заново', () async {
    cubit.selectCell(cellA);
    cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
    cubit.finishCell();
    await cubit.draftWrites;
    await cubit.close(); // кладовщик ушёл с экрана

    final reopened = StockEntryCubit(
      repo,
      catalog,
      drafts,
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    await reopened.restore();

    expect(
      reopened.state.committedCells,
      hasLength(1),
      reason: 'уход с экрана - не повод терять проход',
    );
    await reopened.close();
  });

  // Единственный способ потерять проход намеренно (ADHOC-13). Выход с экрана его не трогает.
  test('отбрасывание прохода стирает слепок и обнуляет состояние', () async {
    cubit.selectCell(cellA);
    cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
    cubit.finishCell();
    await cubit.draftWrites;
    expect(await drafts.load(), isNotNull);

    await cubit.discardPass();

    expect(await drafts.load(), isNull);
    expect(cubit.state.committedCells, isEmpty);
    expect(cubit.state.lines, isEmpty);
  });

  test(
    'битый слепок не роняет экран, а начинается с чистого прохода',
    () async {
      cubit.selectCell(cellA);
      cubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
      await cubit.draftWrites;
      await db.customStatement(
        "UPDATE entry_drafts SET payload = 'не json' WHERE id = 'current'",
      );

      final restored = StockEntryCubit(
        repo,
        catalog,
        drafts,
        const LoadUnitIdGenerator(Uuid()),
        _MockPrinter(),
      );
      await restored.restore();

      expect(restored.state.cell, isNull);
      expect(restored.state.lines, isEmpty);
      await restored.close();
    },
  );

  // Тот же критерий, что у очереди: проверка имеет силу только на базе-файле, потому что
  // «перезапуск» - это закрытие и открытие базы заново, а не создание второго объекта.
  test('проход переживает перезапуск приложения', () async {
    final dir = await Directory.systemTemp.createTemp('craft_wms_draft');
    final file = File('${dir.path}/craft_wms.sqlite');
    addTearDown(() => dir.delete(recursive: true));

    final first = AppDatabase.forTesting(NativeDatabase(file));
    final firstCubit = StockEntryCubit(
      repo,
      _MockCatalog(),
      EntryDraftStore(first),
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    firstCubit.selectCell(cellA);
    firstCubit.addLine(good: goodA, date: '15.01.2026', qty: 10);
    firstCubit.finishCell();
    firstCubit.selectCell(cellB);
    firstCubit.addLine(good: goodA, date: '16.01.2026', qty: 3);
    await firstCubit.draftWrites;
    await firstCubit.close();
    await first.close(); // «приложение убито посреди прохода»

    final second = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(() => second.close());
    final secondCubit = StockEntryCubit(
      repo,
      _MockCatalog(),
      EntryDraftStore(second),
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    await secondCubit.restore();

    expect(secondCubit.state.committedCells, hasLength(1));
    expect(secondCubit.state.committedCells.single.cell.id, cellA.id);
    expect(secondCubit.state.cell?.id, cellB.id);
    expect(secondCubit.state.lines.single.qty, 3);
    await secondCubit.close();
  });
}
