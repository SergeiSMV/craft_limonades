import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/data/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:craft_wms/features/stock_entry/presentation/widgets/cell_entry_view.dart';
import 'package:craft_wms/features/stock_entry/presentation/widgets/cell_select_view.dart';
import 'package:craft_wms/features/stock_entry/presentation/widgets/good_picker_sheet.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_scanner_service.dart';

class _MockEntryRepo extends Mock implements StockEntryRepository {}

class _MockCatalogRepo extends Mock implements CatalogRepository {}

/// Скан кода не того типа в потоке «Ввод остатков».
///
/// Раньше адрес ячейки, отсканированный в поле товара, шёл общим путём «ШК не найден» и открывал
/// ручной выбор товара — а выбранному товару адрес ячейки привязывался как штрихкод. Это порча
/// справочника, а не опечатка, поэтому такой код теперь отсекается по классификации.
void main() {
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  late _MockEntryRepo entryRepo;
  late _MockCatalogRepo catalogRepo;
  late StockEntryCubit cubit;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    entryRepo = _MockEntryRepo();
    catalogRepo = _MockCatalogRepo();
    cubit = StockEntryCubit(entryRepo);

    // Ни один сканированный код не привязан к товару — интересует именно ветка «не нашли».
    when(
      () => entryRepo.resolveGoodByBarcode(any()),
    ).thenAnswer((_) async => const Right<Failure, Good?>(null));
    when(
      () => catalogRepo.listAllCells(),
    ).thenAnswer((_) async => const Right([cell]));

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

  testWidgets('адрес ячейки в поле товара: сообщение вместо выбора товара', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    cubit.selectCell(cell);
    await tester.pumpWidget(wrap(CellEntryView(state: cubit.state)));
    await tester.pump();

    scanner.emit('M1-1-2-2'); // этикетка соседней ячейки
    await tester.pumpAndSettle();

    expect(find.text(t.stockEntry.scannedCellInGood), findsOneWidget);
    expect(find.byType(GoodPickerSheet), findsNothing);
    await scanner.dispose();
  });

  testWidgets('штрихкод товара в поле ячейки: сообщение по существу', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    await tester.pumpWidget(wrap(const CellSelectView(committed: [])));
    await tester.pumpAndSettle(); // дождались загрузки справочника ячеек

    scanner.emit('4607091380001');
    await tester.pumpAndSettle();

    expect(find.text(t.stockEntry.scannedGoodInCell), findsOneWidget);
    expect(find.text(t.stockEntry.cellNotFound), findsNothing);
    await scanner.dispose();
  });

  testWidgets('известный адрес ячейки со сканера выбирает ячейку', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    await tester.pumpWidget(wrap(const CellSelectView(committed: [])));
    await tester.pumpAndSettle();

    scanner.emit('M1-1-1-1');
    await tester.pumpAndSettle();

    expect(cubit.state.cell?.id, 'c1');
    await scanner.dispose();
  });
}
