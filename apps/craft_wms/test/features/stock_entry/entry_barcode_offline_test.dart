import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/widgets/good_picker_sheet.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:craft_wms/features/stock_entry/presentation/widgets/cell_entry_view.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import '../../support/fake_scanner_service.dart';

class _MockPrinter extends Mock implements PrinterService {}

class _MockEntryRepo extends Mock implements StockEntryRepository {}

class _MockCatalogRepo extends Mock implements CatalogRepository {}

/// Скан ШК в проходе, когда проверить код не удалось (ADHOC-13).
///
/// Поток ввода держал собственный резолв поверх `Dio`, мимо кэша устройства, и сводил оба
/// неудачных исхода к `null`: «ШК не привязан» и «проверить не смогли» становились неотличимы.
/// Экран молча открывал выбор товара - то есть предлагал привязку, опираясь на факт, которого
/// у него не было, и заодно показывал снэкбар с ошибкой: два противоречащих сообщения на один скан.
///
/// Привязка офлайн при этом остаётся возможной: кладовщик стоит у стеллажа с упаковкой в руках,
/// и запрет отнял бы у него возможность зафиксировать увиденное. Изменилось то, что причина
/// названа вслух и решение принимает человек, а не приложение за него.
void main() {
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');
  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');
  const code = '4607091380001';

  late _MockEntryRepo entryRepo;
  late _MockCatalogRepo catalogRepo;
  late AppDatabase db;
  late StockEntryCubit cubit;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    entryRepo = _MockEntryRepo();
    catalogRepo = _MockCatalogRepo();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cubit = StockEntryCubit(
      entryRepo,
      catalogRepo,
      EntryDraftStore(db),
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    when(
      () => catalogRepo.listAllCells(),
    ).thenAnswer((_) async => const Right([cell]));
    // Лист ручного выбора товара грузит номенклатуру при открытии.
    when(
      () => catalogRepo.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => const Right(
        Paged<Good>(items: [good], total: 1, limit: 50, offset: 0),
      ),
    );
    if (getIt.isRegistered<CatalogRepository>()) {
      getIt.unregister<CatalogRepository>();
    }
    getIt.registerSingleton<CatalogRepository>(catalogRepo);
  });

  tearDown(() => cubit.close());

  Widget wrap(Widget child) => MaterialApp(
    theme: buildAppTheme(),
    home: BlocProvider<StockEntryCubit>.value(
      value: cubit,
      child: Scaffold(body: child),
    ),
  );

  /// Прокачать экран работы с ячейкой и отсканировать код.
  Future<FakeScannerService> scan(WidgetTester tester, String value) async {
    final scanner = registerFakeScanner();
    cubit.selectCell(cell);
    await tester.pumpWidget(wrap(CellEntryView(state: cubit.state)));
    await tester.pump();
    scanner.emit(value);
    await tester.pumpAndSettle();
    return scanner;
  }

  testWidgets('нет связи: причина названа, выбор товара НЕ открыт сам', (
    tester,
  ) async {
    when(
      () => catalogRepo.resolveGoodByBarcode(code),
    ).thenAnswer((_) async => const Left(Failure.network()));

    final scanner = await scan(tester, code);

    expect(
      find.text(t.stockEntry.barcodeOffline(barcode: code)),
      findsOneWidget,
      reason: 'код не проверен - так и говорим, а не выдаём его за свободный',
    );
    expect(
      find.byType(GoodPickerSheet),
      findsNothing,
      reason: 'сначала спрашиваем, а не открываем выбор товара молча',
    );
    await scanner.dispose();
  });

  // Ради чего правка и делалась: отказ не отнимает у кладовщика возможность работать.
  // Он стоит у стеллажа с упаковкой в руках, и его наблюдение не хуже нашего кэша.
  testWidgets('после подтверждения привязка офлайн проходит', (tester) async {
    when(
      () => catalogRepo.resolveGoodByBarcode(code),
    ).thenAnswer((_) async => const Left(Failure.network()));

    final scanner = await scan(tester, code);
    await tester.tap(find.text(t.stockEntry.bindOfflineConfirm));
    await tester.pumpAndSettle();

    expect(
      find.byType(GoodPickerSheet),
      findsOneWidget,
      reason: 'кладовщик подтвердил - даём выбрать товар',
    );
    await scanner.dispose();
  });

  testWidgets('сервер не смог ответить: сообщение отличается от офлайна', (
    tester,
  ) async {
    when(
      () => catalogRepo.resolveGoodByBarcode(code),
    ).thenAnswer((_) async => const Left(Failure.server(500)));

    final scanner = await scan(tester, code);

    // «Не найден по локальной базе» кладовщик может доверить своей памяти,
    // «не удалось проверить» - повод позвать админа. Путать их нельзя.
    expect(
      find.text(t.stockEntry.barcodeLookupFailed(barcode: code)),
      findsOneWidget,
    );
    await scanner.dispose();
  });

  testWidgets('ШК точно не привязан: привязку по-прежнему предлагаем', (
    tester,
  ) async {
    when(
      () => catalogRepo.resolveGoodByBarcode(code),
    ).thenAnswer((_) async => const Right<Failure, Good?>(null));

    final scanner = await scan(tester, code);

    expect(find.text(t.stockEntry.goodNotBound), findsOneWidget);
    expect(
      find.byType(GoodPickerSheet),
      findsOneWidget,
      reason: 'сервер ответил «не привязан» - это рабочий сценарий прохода',
    );
    await scanner.dispose();
  });

  // Ради чего задача и делалась: привязка из локальной базы узнаётся без связи.
  testWidgets('товар из кэша опознаётся и даёт строку остатка', (tester) async {
    when(
      () => catalogRepo.resolveGoodByBarcode(code),
    ).thenAnswer((_) async => const Right<Failure, Good?>(good));

    final scanner = await scan(tester, code);

    expect(
      find.byType(GoodPickerSheet),
      findsNothing,
      reason: 'товар опознан - выбирать вручную нечего',
    );
    await scanner.dispose();
  });
}
