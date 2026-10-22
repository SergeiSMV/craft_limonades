import 'dart:convert';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_table.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_toolbar.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/documents_tab.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

// ADHOC-26: панель поиска и фильтров закреплена — прокручивается только список под ней.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUp(() {
    // Длинный список: 20 документов — заведомо длиннее экрана.
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
    getIt.registerSingleton<DocumentsRepository>(DocumentsRepository(dio));
  });

  testWidgets('прокрутка списка не уводит панель поиска и фильтров', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Загрузка списка — настоящий асинхронный вызов: даём ему пройти в реальном времени.
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

    // Панель и таблица — одной ширины: панель не сжимается по своему содержимому.
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
    // Строки из прокрутки не пропадают из дерева — проверяем, что список сдвинулся.
    expect(
      tester.getRect(find.text('Поставщик 0')).top,
      lessThan(rowBefore.top - 100),
      reason: 'список не прокрутился',
    );
  });
}
