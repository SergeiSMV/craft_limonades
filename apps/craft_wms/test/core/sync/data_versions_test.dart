import 'dart:async';

import 'package:craft_wms/core/network/data_versions_interceptor.dart';
import 'package:craft_wms/core/sync/catalog_sync_service.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/sync/data_versions_sync.dart';
import 'package:craft_wms/core/widgets/data_versions_listener.dart';
import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/contents_stubs.dart';

class _MockCatalogSync extends Mock implements CatalogSyncService {}

class _MockResponseHandler extends Mock implements ResponseInterceptorHandler {}

class _MockErrorHandler extends Mock implements ErrorInterceptorHandler {}

/// Версии данных сервера на клиенте (ADHOC-60, ADR-0018).
void main() {
  group('DataVersions', () {
    late DataVersions versions;
    late List<Set<String>> events;
    late StreamSubscription<Set<String>> sub;

    setUp(() {
      versions = DataVersions();
      events = [];
      sub = versions.changes.listen(events.add);
    });
    tearDown(() => sub.cancel());

    test('разбор заголовка: кривые части пропускаются', () {
      expect(DataVersions.parse('contents=340, goods=12,bad,x=y,=3'), {
        'contents': 340,
        'goods': 12,
      });
      expect(DataVersions.parse(null), isEmpty);
    });

    test(
      'первый ответ только запоминает, дальше — только выросшие области',
      () async {
        versions.observe('contents=1,goods=1,tasks=1');
        versions.observe('contents=2,goods=1,tasks=1');
        versions.observe(
          'contents=2,goods=1,tasks=1',
        ); // ничего нового — события нет
        versions.observe(
          'contents=1,goods=3,tasks=2',
        ); // contents из старого ответа — не в счёт
        await pumpEventQueue();
        expect(events, [
          {'contents'},
          {'goods', 'tasks'},
        ]);
      },
    );

    test('новая область в заголовке запоминается без события', () async {
      versions.observe('goods=1');
      versions.observe('goods=1,problems=5');
      versions.observe('goods=1,problems=6');
      await pumpEventQueue();
      expect(events, [
        {'problems'},
      ]);
    });

    test(
      'после выхода версии забыты: первый ответ снова только запоминает',
      () async {
        versions.observe('goods=1');
        versions.reset();
        versions.observe('goods=5');
        await pumpEventQueue();
        expect(events, isEmpty);
      },
    );

    test('перехватчик читает заголовок и у ответа с ошибкой', () async {
      final interceptor = DataVersionsInterceptor(versions);
      final opts = RequestOptions(path: 'tasks');
      Response<dynamic> response(String v) => Response(
        requestOptions: opts,
        statusCode: 200,
        headers: Headers.fromMap({
          'X-Data-Versions': [v],
        }),
      );
      interceptor.onResponse(response('tasks=1'), _MockResponseHandler());
      interceptor.onError(
        DioException(requestOptions: opts, response: response('tasks=2')),
        _MockErrorHandler(),
      );
      await pumpEventQueue();
      expect(events, [
        {'tasks'},
      ]);
    });
  });

  group('DataVersionsSync — кэши ТСД', () {
    late DataVersions versions;
    late _MockCatalogSync catalog;
    late FakeContentsSnapshotSync contents;
    late FakeTasksSnapshotSync tasks;
    late DataVersionsSync sync;

    setUp(() {
      versions = DataVersions();
      catalog = _MockCatalogSync();
      when(() => catalog.isRunning).thenReturn(false);
      when(
        () => catalog.refresh(),
      ).thenAnswer((_) async => const Right(SyncOutcome.refreshed));
      contents = FakeContentsSnapshotSync();
      tasks = FakeTasksSnapshotSync();
      sync = DataVersionsSync(versions, catalog, contents, tasks)..start();
      versions.observe('goods=1,cells=1,settings=1,contents=1,tasks=1');
    });
    tearDown(() => sync.stop());

    test('остатки — снимок склада, задания — снимок заданий', () async {
      versions.observe('goods=1,cells=1,settings=1,contents=2,tasks=2');
      await pumpEventQueue();
      expect(contents.requests, 1);
      expect(tasks.requests, 1);
      verifyNever(() => catalog.refresh());
    });

    test('справочник — полная загрузка, снимок она перечитает сама', () async {
      versions.observe('goods=2,cells=1,settings=1,contents=2,tasks=1');
      await pumpEventQueue();
      verify(() => catalog.refresh()).called(1);
      expect(contents.requests, 0);
    });

    test('справочник уже грузится — второй загрузки нет', () async {
      when(() => catalog.isRunning).thenReturn(true);
      versions.observe('goods=2,cells=1,settings=1,contents=1,tasks=1');
      await pumpEventQueue();
      verifyNever(() => catalog.refresh());
    });

    test('после выхода изменения не обрабатываются', () async {
      sync.stop();
      versions.observe('goods=1,contents=1');
      versions.observe('goods=1,contents=9');
      await pumpEventQueue();
      expect(contents.requests, 0);
    });
  });

  testWidgets('DataVersionsListener: пачка событий — одно перечитывание', (
    tester,
  ) async {
    final versions = DataVersions()..observe('tasks=1,goods=1');
    var calls = 0;
    await tester.pumpWidget(
      DataVersionsListener(
        versions: versions,
        domains: const {DataDomain.tasks},
        onChanged: () => calls++,
        child: const SizedBox(),
      ),
    );
    versions
      ..observe('tasks=2,goods=1')
      ..observe('tasks=3,goods=1')
      ..observe('tasks=3,goods=2'); // чужая область — не в счёт
    await tester.pump(DataVersionsListener.debounce);
    expect(calls, 1);
  });
}
