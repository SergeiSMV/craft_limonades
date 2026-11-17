import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/features/stock/presentation/pages/goods_list_page.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';
import '../../support/entry_draft_stub.dart';
import '../../support/fake_scanner_service.dart';

class _MockCatalog extends Mock implements CatalogRepository {}

/// «Остатки» → вкладка «Короба» (P5-05-1): список, поиск по коду с ярлыка, скан не-короба.
void main() {
  late FakeContentsRepository contents;
  late FakeScannerService scanner;

  const a = LoadUnitView(
    id: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
    cellAddress: 'A-1-1',
    live: true,
  );
  const b = LoadUnitView(
    id: '11111111-2222-4333-8444-555566667777',
    cellAddress: 'A-2-1',
    live: true,
  );

  setUp(() {
    registerEmptyDraftStore();
    LocaleSettings.useDeviceLocale();
    scanner = registerFakeScanner();
    contents = registerFakeContentsRepository()..units = const [a, b];
    final catalog = _MockCatalog();
    when(
      () => catalog.listGroups(),
    ).thenAnswer((_) async => const Right(<NomenclatureGroup>[]));
    when(
      () => catalog.listSuppliers(),
    ).thenAnswer((_) async => const Right(<Supplier>[]));
    when(() => catalog.goodsByIds(any())).thenAnswer((_) async => {});
    when(
      () => catalog.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer(
      (_) async => const Right(
        Paged<Good>(items: <Good>[], total: 0, limit: 50, offset: 0),
      ),
    );
    registerStockGoodsCubit(catalog, contents);
  });

  tearDown(() => scanner.dispose());

  Future<void> openBoxesTab(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: const GoodsListPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.contents.tabBoxes).first);
    await tester.pumpAndSettle();
  }

  testWidgets('вкладка показывает короба с кодом с ярлыка и ячейкой', (
    tester,
  ) async {
    await openBoxesTab(tester);

    expect(find.text(t.contents.boxCode(code: '9FA0 B1C2')), findsOneWidget);
    expect(find.text(t.contents.boxCode(code: '6666 7777')), findsOneWidget);
    expect(find.textContaining('A-1-1'), findsOneWidget);
  });

  testWidgets('код, набранный как на ярлыке, оставляет один короб', (
    tester,
  ) async {
    await openBoxesTab(tester);

    await tester.enterText(find.byType(TextField), '9fa0 b1');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(contents.searches.last, '9FA0B1');
    expect(find.text(t.contents.boxCode(code: '9FA0 B1C2')), findsOneWidget);
    expect(find.text(t.contents.boxCode(code: '6666 7777')), findsNothing);
  });

  testWidgets(
    'скан штрихкода товара на вкладке «Короба» - «не ячейка и не короб»',
    (tester) async {
      await openBoxesTab(tester);

      scanner.emit('4601234567890');
      await tester.pumpAndSettle();

      expect(find.text(t.contents.notCellOrBox), findsOneWidget);
    },
  );
}
