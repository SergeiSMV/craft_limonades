import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_device.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
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

void main() {
  const goodA = Good(id: 'gA', name: 'Кальмар', uom: 'шт');
  const goodB = Good(id: 'gB', name: 'Креветка', uom: 'кг');
  const defaultCell = Cell(
    id: 'c-def',
    warehouseId: 'w1',
    address: 'С-Н-П',
    isDefault: true,
  );
  const cell1 = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');
  const supplier = Supplier(id: 's1', name: 'Поставщик');

  late _MockCatalog catalog;
  late _MockRepo repo;
  late _MockPrinter printer;
  late AppDatabase db;
  late ReceiptDraftStore drafts;
  late ReceiptCubit cubit;

  ReceiptCubit newCubit() => ReceiptCubit(
    catalog,
    repo,
    drafts,
    const LoadUnitIdGenerator(Uuid()),
    printer,
  );

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    catalog = _MockCatalog();
    repo = _MockRepo();
    printer = _MockPrinter();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    drafts = ReceiptDraftStore(db);
    cubit = newCubit();
    when(
      () => catalog.defaultCell(),
    ).thenAnswer((_) async => const Right(defaultCell));
    when(
      () => catalog.bindBarcode(
        goodId: any(named: 'goodId'),
        barcode: any(named: 'barcode'),
      ),
    ).thenAnswer((_) async => const Right(null));
  });

  tearDown(() => db.close());

  group('начало приёмки', () {
    test('без ячейки по умолчанию приёмка не начинается', () async {
      when(
        () => catalog.defaultCell(),
      ).thenAnswer((_) async => const Right(null));
      await cubit.start(supplier);
      expect(cubit.state.started, isFalse);
      expect(cubit.state.failure, const Failure.unknown(kNoDefaultCell));
    });

    test('начало выдаёт id документа и запоминает склад по ячейке', () async {
      await cubit.start(supplier);
      expect(cubit.state.started, isTrue);
      expect(cubit.state.receiptId, isNotNull);
      expect(cubit.state.defaultCell, defaultCell);
      expect(cubit.state.supplier, supplier);
    });
  });

  group('строки: короб и штучно', () {
    setUp(() => cubit.start(supplier));

    test(
      'штучная строка ложится в текущую ячейку; повтор грани копит',
      () async {
        await cubit.addLine(good: goodA, date: '01.09.2026', qty: 5);
        await cubit.addLine(good: goodA, date: '01.09.2026', qty: 2);
        expect(cubit.state.lines.single.qty, 7);
        expect(cubit.state.lines.single.cell, isNull); // ячейка по умолчанию

        cubit.setTargetCell(cell1);
        await cubit.addLine(good: goodA, date: '01.09.2026', qty: 1);
        // Другая ячейка — другая грань, отдельная строка.
        expect(cubit.state.lines.length, 2);
        expect(cubit.state.lines.last.cell, cell1);
      },
    );

    test('короб получает ячейку на момент создания', () async {
      cubit.setTargetCell(cell1);
      final boxId = cubit.newBox();
      // Ячейку общего списка сменили после создания короба: строки короба остаются
      // в его ячейке — короб не может лежать в двух местах.
      cubit.setTargetCell(defaultCell);
      await cubit.addLine(
        good: goodB,
        date: '01.09.2026',
        qty: 3,
        boxId: boxId,
      );
      expect(cubit.state.lines.single.boxId, boxId);
      expect(cubit.state.lines.single.cell, cell1);
      // Дефолтная ячейка сбрасывает выбор, а не становится «выбранной».
      expect(cubit.state.targetCell, isNull);
    });

    test('без короба строка ложится штучно, даже если короба есть', () async {
      cubit.newBox();
      await cubit.addLine(good: goodA, date: '01.09.2026', qty: 1);
      expect(cubit.state.looseLines.single.boxId, isNull);
    });

    // ADHOC-18: ячейка на странице короба переносит короб целиком.
    test('смена ячейки короба переносит все его строки', () async {
      final boxId = cubit.newBox();
      await cubit.addLine(
        good: goodA,
        date: '01.09.2026',
        qty: 1,
        boxId: boxId,
      );
      await cubit.addLine(
        good: goodB,
        date: '02.09.2026',
        qty: 2,
        boxId: boxId,
      );
      await cubit.addLine(good: goodA, date: '01.09.2026', qty: 5); // штучно

      cubit.setBoxCell(boxId, cell1);
      expect(cubit.state.boxById(boxId)!.cell, cell1);
      expect(cubit.state.linesOf(boxId).map((l) => l.cell), [cell1, cell1]);
      // Штучная строка осталась на месте.
      expect(cubit.state.looseLines.single.cell, isNull);

      // Обратно в ячейку по умолчанию — флагом, а не «выбранной» дефолтной.
      cubit.setBoxCell(boxId, defaultCell);
      expect(cubit.state.boxById(boxId)!.cell, isNull);
      expect(cubit.state.linesOf(boxId).every((l) => l.cell == null), isTrue);
    });

    // ADHOC-18: короб удаляется до завершения приёмки вместе с позициями.
    test('удаление короба убирает его позиции, остальное не трогает', () async {
      final boxA = cubit.newBox();
      final boxB = cubit.newBox();
      await cubit.addLine(good: goodA, date: '01.09.2026', qty: 1, boxId: boxA);
      await cubit.addLine(good: goodB, date: '01.09.2026', qty: 2, boxId: boxB);
      await cubit.addLine(good: goodA, date: '01.09.2026', qty: 3);

      cubit.removeBox(boxA);
      expect(cubit.state.boxes.map((b) => b.id), [boxB]);
      expect(cubit.state.linesOf(boxA), isEmpty);
      expect(cubit.state.lines.length, 2);
    });

    test('свой короб узнаётся по ярлыку в любом регистре, чужой — нет', () {
      final boxId = cubit.newBox();
      expect(cubit.hasBox(const Uuid().v4()), isFalse);
      expect(cubit.hasBox(boxId.toUpperCase()), isTrue);
    });

    test('новый ШК уходит привязкой в очередь', () async {
      await cubit.addLine(
        good: goodA,
        date: '01.09.2026',
        qty: 1,
        newBarcode: '4600000000017',
      );
      verify(
        () => catalog.bindBarcode(goodId: 'gA', barcode: '4600000000017'),
      ).called(1);
    });
  });

  group('завершение', () {
    setUp(() => cubit.start(supplier));

    test(
      'тело операции: склад, поставщик, только непустые короба, формат даты',
      () async {
        final usedBox = cubit.newBox();
        await cubit.addLine(
          good: goodA,
          date: '01.09.2026',
          qty: 12,
          boxId: usedBox,
        );
        cubit.newBox(); // пустой короб — на сервер не едет
        await cubit.addLine(good: goodB, date: '02.09.2026', qty: 1.5);

        Map<String, dynamic>? sent;
        when(() => repo.submit(any())).thenAnswer((inv) async {
          sent = inv.positionalArguments.first as Map<String, dynamic>;
          return const Right(null);
        });
        await cubit.submit();

        expect(cubit.state.outcome, ReceiptOutcome.posted);
        expect(sent!['receipt_id'], cubit.state.receiptId);
        expect(sent!['warehouse_id'], 'w1');
        expect(sent!['supplier_id'], 's1');
        expect(sent!['load_units'], [
          {'id': usedBox, 'kind': 'box'},
        ]);
        final lines = sent!['lines'] as List;
        expect(lines[0], {
          'good_id': 'gA',
          'production_date': '01-09-2026',
          'qty': 12.0,
          'load_unit_id': usedBox,
        });
        // Ячейка по умолчанию не указывается: подставляет её сервер.
        expect((lines[1] as Map).containsKey('cell_id'), isFalse);
        expect((lines[1] as Map).containsKey('load_unit_id'), isFalse);
      },
    );

    test(
      'без связи приёмка сохраняется в очереди, черновик стирается',
      () async {
        await cubit.addLine(good: goodA, date: '01.09.2026', qty: 1);
        await cubit.draftWrites;
        expect(await drafts.load(), isNotNull);

        when(
          () => repo.submit(any()),
        ).thenAnswer((_) async => const Left(Failure.network()));
        await cubit.submit();
        await cubit.draftWrites;

        expect(cubit.state.outcome, ReceiptOutcome.queued);
        expect(await drafts.load(), isNull);
      },
    );

    test('отказ сервера показывается с причиной', () async {
      await cubit.addLine(good: goodA, date: '01.09.2026', qty: 1);
      when(() => repo.submit(any())).thenAnswer(
        (_) async => const Left(Failure.rejected('receipt already posted')),
      );
      await cubit.submit();
      expect(cubit.state.outcome, ReceiptOutcome.rejected);
      expect(cubit.state.rejectReason, 'receipt already posted');
    });

    test('пустую приёмку не отправить', () async {
      await cubit.submit();
      verifyNever(() => repo.submit(any()));
    });
  });

  test(
    'приёмка переживает перезапуск: короба, ячейки и строки на месте',
    () async {
      await cubit.start(supplier);
      cubit.setTargetCell(cell1);
      final boxId = cubit.newBox();
      await cubit.addLine(
        good: goodA,
        date: '01.09.2026',
        qty: 4,
        boxId: boxId,
      );
      await cubit.draftWrites;

      final restored = newCubit();
      await restored.restore();
      expect(restored.state.started, isTrue);
      expect(restored.state.receiptId, cubit.state.receiptId);
      expect(restored.state.supplier, supplier);
      expect(restored.state.targetCell, cell1);
      expect(restored.state.linesOf(boxId).single.good, goodA);
      expect(restored.state.boxes.single.cell, cell1);
      expect(restored.state.lines.single.good, goodA);
      await restored.close();
    },
  );

  test('ошибка принтера возвращается текстом и приёмку не трогает', () async {
    await cubit.start(supplier);
    final boxId = cubit.newBox();
    when(() => printer.printLoadUnitLabel(boxId)).thenThrow(
      const PrinterFailure(PrinterFailureKind.io, 'Принтер не выбран'),
    );
    expect(await cubit.printBoxLabel(boxId), 'Принтер не выбран');
    expect(cubit.state.boxes.single.id, boxId);
  });
}
