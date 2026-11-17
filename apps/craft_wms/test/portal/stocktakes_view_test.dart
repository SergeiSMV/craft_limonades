import 'dart:convert';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/stocktakes/stocktakes_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/stocktake/stocktake_card.dart';
import 'package:craft_wms/portal/presentation/widgets/stocktake/stocktakes_view.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:craft_wms/portal/data/stocktakes_repository_impl.dart';

import '../support/fake_dio_adapter.dart';

// ADHOC-56: «Пересчёты» в плоском стиле - список по фильтру, кнопки по праву, заведение
// (вид области, объекты галочками, отправка), подтверждение закрытия, узкое окно.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  late RecordingAdapter adapter;

  ResponseBody json(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  Map<String, Object?> stocktake(int n, String status, {int counted = 1}) => {
    'id': 's$n',
    'number': n,
    'scope_kind': 'cells',
    'status': status,
    'created_by': 'Иванов Иван',
    'created_at': '2026-11-01T10:00:00Z',
    'closed_at': status == 'closed' ? '2026-11-02T10:00:00Z' : null,
    'cells': 3,
    'counted': counted,
  };

  setUp(() {
    adapter = RecordingAdapter({
      'GET ${ApiConst.stocktakes}': (o) => json(
        o.queryParameters['status'] == 'closed'
            ? [stocktake(1, 'closed', counted: 3)]
            : [stocktake(2, 'in_progress'), stocktake(3, 'new', counted: 0)],
      ),
      'POST ${ApiConst.stocktakes}': (_) => json({'number': 4, 'cells': 2}),
      'POST ${ApiConst.stocktakeClose('s2')}': (_) => json(<String, Object>{}),
      'GET ${ApiConst.cells}': (o) => json({
        'items': [
          {'id': 'c1', 'address': 'A-01-1', 'warehouse_id': 'w1'},
          {'id': 'c2', 'address': 'A-01-2', 'warehouse_id': 'w1'},
        ],
      }),
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = adapter;
    if (getIt.isRegistered<StocktakesRepository>()) {
      getIt.unregister<StocktakesRepository>();
    }
    getIt.registerSingleton<StocktakesRepository>(StocktakesRepositoryImpl(dio));
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
  });

  /// Открыть страницу шириной [width] и дождаться загрузки.
  Future<void> open(
    WidgetTester tester, {
    bool canManage = true,
    double width = 1200,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StocktakesView(canManage: canManage)),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  /// Нажать и дать сети ответить.
  Future<void> tapAndWait(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('открытые строками, «Закрытые» - закрытые', (tester) async {
    await open(tester);
    expect(find.byType(StocktakeCard), findsNWidgets(2));
    expect(find.text(t.portal.stocktake.statusInProgress), findsOneWidget);
    expect(
      find.text(t.portal.stocktake.close),
      findsNWidgets(2),
      reason: '«Закрыть» у каждого открытого',
    );

    await tapAndWait(tester, find.text(t.portal.stocktake.filterClosed));
    expect(find.byType(StocktakeCard), findsOneWidget);
    expect(find.text(t.portal.stocktake.statusClosed), findsOneWidget);
    expect(find.text(t.portal.stocktake.close), findsNothing);
  });

  testWidgets('без права заводить - ни «Завести», ни «Закрыть»', (
    tester,
  ) async {
    await open(tester, canManage: false);
    expect(find.text(t.portal.stocktake.create), findsNothing);
    expect(find.text(t.portal.stocktake.close), findsNothing);
    expect(find.text(t.portal.stocktake.showProgress), findsNWidgets(2));
  });

  testWidgets('завести: ячейки галочками, выбранные отметками, отправка', (
    tester,
  ) async {
    await open(tester);
    await tapAndWait(tester, find.text(t.portal.stocktake.create));
    expect(find.text(t.portal.stocktake.createTitle), findsOneWidget);
    expect(find.text('A-01-1'), findsOneWidget);

    await tapAndWait(tester, find.text('A-01-1'));
    expect(find.text(t.portal.stocktake.picked(count: 1)), findsOneWidget);
    // Выбранная - ещё и отметкой над списком.
    expect(find.text('A-01-1'), findsNWidgets(2));

    await tapAndWait(tester, find.text(t.portal.stocktake.createSubmit));
    final post = adapter.requests.lastWhere((r) => r.method == 'POST');
    expect((post.data as Map)['object_ids'], ['c1']);
    expect((post.data as Map)['warehouse_id'], 'w1');
    expect(find.text(t.portal.stocktake.createTitle), findsNothing);
  });

  testWidgets('закрыть - с подтверждением, неподсчитанные досрочно', (
    tester,
  ) async {
    await open(tester);
    await tapAndWait(tester, find.text(t.portal.stocktake.close).first);
    expect(
      find.text(t.portal.stocktake.closeBodyUncounted(count: 2)),
      findsOneWidget,
    );
    await tapAndWait(tester, find.text(t.portal.stocktake.closeYes).last);
    final post = adapter.requests.lastWhere((r) => r.method == 'POST');
    expect(post.path, ApiConst.stocktakeClose('s2'));
    expect((post.data as Map)['force'], isTrue);
  });

  testWidgets('узко - без переполнения, кнопки в строке', (tester) async {
    await open(tester, width: 375);
    expect(tester.takeException(), isNull);
    expect(find.byType(StocktakeCard), findsNWidgets(2));
    expect(find.text(t.portal.stocktake.showProgress), findsNWidgets(2));
  });
}
