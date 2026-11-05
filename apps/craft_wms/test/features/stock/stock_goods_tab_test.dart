import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/domain/stock_entities.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/pages/goods_list_page.dart';
import 'package:craft_wms/features/stock/presentation/widgets/goods_list/stock_filter_button.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';
import '../../support/entry_draft_stub.dart';
import '../../support/fake_scanner_service.dart';

class _MockCatalog extends Mock implements CatalogRepository {}

/// «Остатки» → вкладка «Товары» (ADHOC-33): количество в строке, подпись снимка, фильтр складов.
void main() {
  late FakeScannerService scanner;
  late FakeContentsRepository contents;

  setUp(() {
    registerEmptyDraftStore();
    LocaleSettings.useDeviceLocale();
    scanner = registerFakeScanner();
    contents = registerFakeContentsRepository()
      ..goods = const [
        GoodStock(
          goodId: 'g1',
          name: 'Кальмар',
          code: '16121',
          byWarehouse: {null: 10, 'iwh-defect': 2.5},
        ),
      ]
      ..unitsFreshness = FromSnapshot(DateTime(2026, 10, 21, 9, 5));
    final catalog = _MockCatalog();
    when(() => catalog.listGroups()).thenAnswer((_) async => const Right([]));
    when(
      () => catalog.listSuppliers(),
    ).thenAnswer((_) async => const Right(<Supplier>[]));
    when(() => catalog.goodsByIds(any())).thenAnswer((_) async => {});
    registerStockGoodsCubit(
      catalog,
      contents,
      warehouses: const [
        InternalWarehouse(
          id: 'iwh-main',
          code: 'MAIN',
          name: 'Основной',
          isDefault: true,
        ),
        InternalWarehouse(
          id: 'iwh-defect',
          code: 'DEFECT',
          name: 'Брак',
          isDefault: false,
        ),
      ],
    );
  });

  tearDown(() => scanner.dispose());

  testWidgets('строка с количеством; фильтр «Брак» оставляет его остаток', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Кальмар'), findsOneWidget);
    expect(find.text('12.5'), findsOneWidget);
    expect(
      find.text(t.contents.snapshotNote(time: '21.10 09:05')),
      findsOneWidget,
    );

    await tester.tap(find.byType(FilterButton));
    await tester.pumpAndSettle();
    expect(find.text(t.stockListScreen.filterWarehouses), findsOneWidget);
    await tester.tap(find.text('Брак'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Брак').last)).pop();
    await tester.pumpAndSettle();

    expect(find.text('2.5'), findsOneWidget);
    // Активный фильтр — чипом под поиском.
    expect(find.widgetWithText(Chip, 'Брак'), findsOneWidget);
  });
}
