import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/catalog/portal_catalog_repository.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/portal/domain/internal_warehouses/internal_warehouses_repository.dart';
import 'package:craft_wms/portal/domain/stock/warehouse_stock_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/stock_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_input.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements WarehouseStockRepository {}

class _MockApi extends Mock implements PortalCatalogRepository {}

PortalWarehouse warehouse(String id) => PortalWarehouse(
  id: id,
  code: id,
  name: 'Склад $id',
  isDefault: id == 'w1',
  isActive: true,
  inUse: true,
);

PortalStockGood good(String id, String name, Map<String, double> by) =>
    PortalStockGood(
      good: Good(id: id, name: name, uom: 'шт'),
      byWarehouse: by,
    );

/// ADHOC-56: «Остатки склада» - остаток в строке, поиск и склад отбирают в памяти.
void main() {
  late _MockRepo repo;

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
    repo = _MockRepo();
    final api = _MockApi();
    getIt
      ..registerSingleton<WarehouseStockRepository>(repo)
      ..registerSingleton<PortalCatalogRepository>(api);
    when(
      () => api.listGoodBarcodes(any()),
    ).thenAnswer((_) async => const Right([]));
    when(() => api.listGroups()).thenAnswer((_) async => const Right([]));
    when(
      () => api.listSuppliers(query: any(named: 'query')),
    ).thenAnswer((_) async => const Right([]));
    when(() => repo.load(refresh: any(named: 'refresh'))).thenAnswer(
      (_) async => Right(
        PortalStock(
          asOf: DateTime(2026, 10, 30, 12),
          goods: [
            good('g1', 'Чипсы', {'w1': 3, 'w2': 5}),
            good('g2', 'Сухарики', {'w2': 2}),
          ],
          places: const {
            'g1': [
              PortalStockPlace(
                cellAddress: 'A-01-01',
                productionDate: '01-02-2026',
                qty: 3,
                warehouseId: 'w1',
                warehouseName: 'Склад w1',
              ),
              PortalStockPlace(
                cellAddress: 'A-01-02',
                loadUnitId: '00000000-0000-0000-0000-000000000abc',
                productionDate: '15-03-2026',
                qty: 5,
                warehouseId: 'w2',
                warehouseName: 'Склад w2',
                onDefaultWarehouse: false,
              ),
            ],
          },
          warehouses: [warehouse('w1'), warehouse('w2')],
        ),
      ),
    );
  });

  tearDown(getIt.reset);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StockTab())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('строки с остатком на всех складах', (tester) async {
    await pump(tester);
    expect(find.text(t.portal.goods.colQty), findsOneWidget);
    expect(find.text('8 шт'), findsOneWidget);
    expect(find.text('2 шт'), findsOneWidget);
    expect(find.text(t.portal.goods.shown(shown: 2, total: 2)), findsOneWidget);
  });

  testWidgets('склад отбирает товары с остатком на нём', (tester) async {
    await pump(tester);
    await tester.tap(find.text('${t.portal.stock.warehouse}: '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Склад w1').last);
    await tester.pumpAndSettle();
    expect(find.text('3 шт'), findsOneWidget);
    expect(find.text('Сухарики'), findsNothing);
  });

  testWidgets('поиск - по словам наименования', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(PortalInput),
        matching: find.byType(TextField),
      ),
      'сухар',
    );
    await tester.pumpAndSettle();
    expect(find.text('Чипсы'), findsNothing);
    expect(find.text('Сухарики'), findsOneWidget);
  });

  testWidgets('«Обновить» снимает свежий снимок', (tester) async {
    await pump(tester);
    await tester.tap(find.text(t.portal.stock.refresh));
    await tester.pumpAndSettle();
    verify(() => repo.load(refresh: any(named: 'refresh'))).called(2);
  });

  testWidgets('карточка - наличие по местам хранения и итог', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Чипсы'));
    await tester.pumpAndSettle();
    expect(find.text(t.portal.goods.cardPlaces), findsOneWidget);
    expect(find.text('A-01-01'), findsOneWidget);
    expect(
      find.text(t.portal.goods.cardBatch(date: '15.03.2026')),
      findsOneWidget,
    );
    expect(find.textContaining('Короб: '), findsOneWidget);
    // Склад подписан только у не основного.
    expect(find.text('Склад w2'), findsOneWidget);
    expect(find.text(t.portal.goods.cardTotal), findsOneWidget);
    expect(find.text('8 шт'), findsNWidgets(2));
  });
}
