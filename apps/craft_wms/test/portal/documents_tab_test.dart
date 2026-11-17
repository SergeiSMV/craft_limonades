import 'dart:convert';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/documents/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_card.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_table.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_toolbar.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/documents_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/inventory_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_choice.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:craft_wms/portal/data/documents_repository_impl.dart';

import '../support/fake_dio_adapter.dart';

// ADHOC-26: панель поиска и фильтров закреплена - прокручивается только список под ней;
// ADHOC-56: узкая раскладка и переключатель видов «Инвентаризации».
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUp(() {
    // Длинный список: 20 документов - заведомо длиннее экрана.
    final docs = [
      for (var i = 0; i < 20; i++)
        {
          'id': 'd$i',
          'kind': 'receipt',
          'supplier': 'Поставщик $i',
          'doc_number': 'ТН-$i',
          'doc_date': '01-10-2026',
          'warehouse_code': 'SHB',
          'warehouse_name': 'Шабулина',
          'created_at': '2026-10-09T10:00:00Z',
          'lines_count': 1,
          'status': i.isEven ? 'new' : 'done',
        },
    ];
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString(
          jsonEncode(docs),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });
    if (getIt.isRegistered<DocumentsRepository>()) {
      getIt.unregister<DocumentsRepository>();
    }
    getIt.registerSingleton<DocumentsRepository>(DocumentsRepositoryImpl(dio));
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
  });

  testWidgets('прокрутка списка не уводит панель поиска и фильтров', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Загрузка списка - настоящий асинхронный вызов: даём ему пройти в реальном времени.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DocumentsTab(kind: 'receipt', empty: 'пусто'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Поставщик 0'), findsOneWidget);

    // Панель и таблица - одной ширины: панель не сжимается по своему содержимому.
    expect(
      tester.getRect(find.byType(DocToolbar)).width,
      tester.getRect(find.byType(DocTable)).width,
      reason: 'панель поиска и таблица разной ширины',
    );

    final before = tester.getRect(find.byType(DocToolbar));
    final rowBefore = tester.getRect(find.text('Поставщик 0'));
    await tester.drag(find.text('Поставщик 0'), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(DocToolbar)),
      before,
      reason: 'панель уехала со списком',
    );
    // Строки из прокрутки не пропадают из дерева - проверяем, что список сдвинулся.
    expect(
      tester.getRect(find.text('Поставщик 0')).top,
      lessThan(rowBefore.top - 100),
      reason: 'список не прокрутился',
    );
  });

  /// Открыть [child] шириной [width] и дождаться загрузки списка.
  Future<void> open(WidgetTester tester, Widget child, double width) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  // ADHOC-56: на телефоне вместо таблицы - строки, каждый факт своей подписанной строкой.
  testWidgets('узко - строки вместо таблицы, без переполнения', (tester) async {
    await open(
      tester,
      const DocumentsTab(kind: 'receipt', empty: 'пусто'),
      400,
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsNothing);
    expect(find.byType(DocCard), findsWidgets);
    expect(
      find.text(
        t.portal.documents.line(
          label: t.portal.receipt.colParty,
          value: 'Поставщик 0',
        ),
      ),
      findsOneWidget,
    );
  });

  // ADHOC-56: переключатель видов «Инвентаризации» закреплён над панелью документов.
  testWidgets('инвентаризация - переключатель над панелью, смена вида', (
    tester,
  ) async {
    const rights = (view: true, download: true, post: true);
    await open(
      tester,
      const InventoryTab(
        stocktakes: false,
        canManage: false,
        stocktakeDocs: rights,
        stockEntryDocs: rights,
      ),
      1200,
    );
    final entry = find.text(t.portal.stocktake.viewStockEntry);
    expect(
      tester.getRect(entry).bottom,
      lessThan(tester.getRect(find.byType(DocToolbar)).top),
      reason: 'переключатель не над панелью',
    );
    await tester.runAsync(() async {
      await tester.tap(entry);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final tab = tester.widget<DocumentsTab>(find.byType(DocumentsTab));
    expect(tab.kind, 'stock_entry');
    expect(find.byType(PortalChoice), findsNWidgets(2 + 3)); // виды + фильтры
  });
}
