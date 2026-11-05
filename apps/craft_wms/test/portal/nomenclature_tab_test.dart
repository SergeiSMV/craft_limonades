import 'package:craft_wms/core/constants/app_insets.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/nomenclature_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_input.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements CatalogApi {}

Good good(int i) => Good(
  id: 'g$i',
  code: '${16000 + i}',
  name: 'Товар $i',
  uom: 'шт',
  groupName: 'Морепродукты',
  supplierName: 'ООО «Голсера»',
  czMarked: i == 1,
);

/// ADHOC-56: «Номенклатура склада» — список страницами, «Показать ещё», загрузка по праву.
void main() {
  late _MockApi api;

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
    api = _MockApi();
    getIt.registerSingleton<CatalogApi>(api);
    when(() => api.listGroups()).thenAnswer((_) async => const Right([]));
    when(
      () => api.listSuppliers(query: any(named: 'query')),
    ).thenAnswer((_) async => const Right([]));
    when(
      () => api.listGoods(
        query: any(named: 'query'),
        groupId: any(named: 'groupId'),
        supplierId: any(named: 'supplierId'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((inv) async {
      final offset = inv.namedArguments[#offset] as int;
      return Right(
        Paged(
          items: [for (var i = offset; i < offset + 2 && i < 3; i++) good(i)],
          total: 3,
          limit: 2,
          offset: offset,
        ),
      );
    });
  });

  tearDown(getIt.reset);

  Future<void> pump(
    WidgetTester tester, {
    double width = 1200,
    double height = 900,
    bool canImport = true,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NomenclatureTab(canImport: canImport)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('широко — таблица с шапкой; «Показать ещё» дописывает страницу', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(t.portal.goods.colCode), findsOneWidget);
    expect(find.text('Товар 0'), findsOneWidget);
    expect(find.text(t.portal.goods.cz), findsOneWidget);
    expect(find.text(t.portal.goods.shown(shown: 2, total: 3)), findsOneWidget);

    await tester.tap(find.text(t.portal.goods.more));
    await tester.pumpAndSettle();
    expect(find.text('Товар 2'), findsOneWidget);
    expect(find.text(t.portal.goods.more), findsNothing);
  });

  testWidgets('узко — реквизиты подписанными строками, без шапки колонок', (
    tester,
  ) async {
    await pump(tester, width: 400);
    expect(find.text(t.portal.goods.colCode), findsNothing);
    expect(find.text(t.portal.goods.code(value: '16000')), findsOneWidget);
  });

  testWidgets('«Загрузить из 1С» — только с правом загрузки', (tester) async {
    await pump(tester, canImport: false);
    expect(find.text(t.portal.goods.import), findsNothing);
    await pump(tester);
    expect(find.text(t.portal.goods.import), findsOneWidget);
  });

  testWidgets('панель поиска закреплена: прокрутка списка её не уводит', (
    tester,
  ) async {
    await pump(tester, width: 400, height: 300);
    final before = tester.getTopLeft(find.byType(PortalInput));
    await tester.drag(find.text('Товар 1'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(PortalInput)), before);
  });

  testWidgets('панель поиска — от левого края таблицы', (tester) async {
    await pump(tester, width: 1600);
    expect(
      tester.getTopLeft(find.byType(PortalInput)).dx,
      tester.getTopLeft(find.text(t.portal.goods.colName)).dx -
          AppInsets.tableHead.left,
    );
  });

  testWidgets(
    'нажатие на строку — карточка товара с реквизитами и штрихкодами',
    (tester) async {
      when(() => api.listGoodBarcodes('g1')).thenAnswer(
        (_) async => const Right([
          Barcode(barcode: '4600000000017', symbology: 'EAN-13'),
          Barcode(barcode: '2000000000015'),
        ]),
      );
      await pump(tester);
      await tester.tap(find.text('Товар 1'));
      await tester.pumpAndSettle();

      expect(find.text(t.portal.goods.cardBarcodes(count: 2)), findsOneWidget);
      expect(find.text('4600000000017'), findsOneWidget);
      expect(find.text(t.portal.goods.cardUom), findsOneWidget);
      // Маркируемый — отметка «ЧЗ» и в строке, и в карточке.
      expect(find.text(t.portal.goods.cz), findsNWidgets(2));
    },
  );
}
