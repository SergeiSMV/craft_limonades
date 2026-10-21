import 'dart:convert';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/contents/data/contents_cache.dart';
import 'package:craft_wms/features/problems/data/problem_records_repository_impl.dart';
import 'package:craft_wms/features/problems/domain/problem_records.dart';
import 'package:craft_wms/features/problems/presentation/bloc/current_problems_cubit.dart';
import 'package:craft_wms/features/problems/presentation/widgets/current/current_problems_view.dart';
import 'package:craft_wms/features/problems/presentation/widgets/records/record_format.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

import '../../support/fake_dio_adapter.dart';

class _MockRepo extends Mock implements ProblemRecordsRepository {}

/// Открытая проблема в ответе `GET /problems/current` — решения ещё нет.
Map<String, dynamic> openJson(String id) => {
  'id': id,
  'created_at': '2026-10-21T09:00:00Z',
  'created_by': 'Иванов Иван',
  'cell_address': 'M1-4-3-2',
  'reason': 'spoilage',
  'comment': 'вернуть',
  'from_warehouse': 'Основной',
  'to_warehouse': 'Брак',
  'items': [
    {
      'good_name': 'Кальмар',
      'production_date': '2026-09-26',
      'qty': '1.000',
      'cell_address': 'M1-4-3-2',
    },
  ],
  'decisions': ['write_off', 'supplier_return'],
  'status': 'open',
};

/// ADHOC-35: вкладка «Текущие» — открытые проблемы склада с сервера и свои неотправленные
/// из очереди; без связи — только свои, с подсказкой.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocaleSettings.useDeviceLocale);

  test(
    'открытая из ответа: решения нет — «ждёт решения офиса», исполнения нет',
    () {
      final p = problemRecordFromJson(openJson('p1'));
      expect(p.isOpen, isTrue);
      expect(p.resolvedAt, isNull);
      expect(outcomeLabel(p), t.problems.awaitingDecision);
      expect(executedMeta(p), isNull);
      expect(
        p.resolvedAtTime,
        p.createdAt,
        reason: 'день в списке — день фиксации',
      );
    },
  );

  group('репозиторий: сервер и своя очередь', () {
    late AppDatabase db;
    late OutboxRepository outbox;
    late Map<String, ResponseBody Function(RequestOptions)> responses;
    late ProblemRecordsRepositoryImpl repo;

    const cell = 'c1';
    const good = 'g1';
    const defect = 'iwh-defect';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      outbox = OutboxRepository(db, const Uuid());
      final catalog = CatalogCache(db);
      await catalog.putCells(const [
        Cell(id: cell, warehouseId: 'w1', address: 'M1-4-3-2'),
      ]);
      await catalog.putGoods(const [
        Good(id: good, code: '16121', name: 'Кальмар', uom: 'шт'),
      ]);
      await db.batch(
        (b) => b.insertAll(db.cachedInternalWarehouses, [
          CachedInternalWarehousesCompanion.insert(
            id: 'iwh-main',
            code: 'MAIN',
            name: 'Основной',
            isDefault: const Value(true),
          ),
          CachedInternalWarehousesCompanion.insert(
            id: defect,
            code: 'DEFECT',
            name: 'Брак',
          ),
        ]),
      );
      responses = {};
      final dio = Dio()..httpClientAdapter = RecordingAdapter(responses);
      repo = ProblemRecordsRepositoryImpl(
        dio,
        outbox,
        catalog,
        ContentsCache(db),
        InternalWarehouses(Dio(), db),
      );
    });

    tearDown(() => db.close());

    Future<void> pendingProblem(String id) => outbox.enqueue(
      kind: OutboxKind.problemSubmit,
      payload: {
        'problem_id': id,
        'warehouse_id': 'w1',
        'good_id': good,
        'production_date': '26-09-2026',
        'qty': 2,
        'cell_id': cell,
        'to_internal_warehouse_id': defect,
        'reason': 'breakage',
      },
    );

    test(
      'свои неотправленные — с подписями из справочников; известная серверу — '
      'один раз',
      () async {
        await pendingProblem('mine');
        await pendingProblem('srv');
        responses['GET problems/current'] = (_) => ResponseBody.fromString(
          jsonEncode([openJson('srv')]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );

        final current = await repo.current();

        expect(current.failure, isNull);
        expect(current.open.map((p) => p.id), ['srv']);
        expect(current.pending.map((p) => p.id), ['mine']);
        final mine = current.pending.single;
        expect(mine.pending, isTrue);
        expect(mine.isOpen, isTrue);
        expect(outcomeLabel(mine), t.problems.pendingSend);
        expect(
          (mine.cellAddress, mine.fromWarehouse, mine.toWarehouse),
          ('M1-4-3-2', 'Основной', 'Брак'),
        );
        expect(mine.items.single.goodName, 'Кальмар');
        expect(
          mine.items.single.productionDate,
          '2026-09-26',
          reason: 'дата очереди — в виде сервера',
        );
      },
    );

    test('без связи — свои неотправленные и причина', () async {
      await pendingProblem('mine');
      responses['GET problems/current'] = (o) => throw DioException(
        requestOptions: o,
        type: DioExceptionType.connectionError,
      );

      final current = await repo.current();

      expect(current.failure, isA<NetworkFailure>());
      expect(current.open, isEmpty);
      expect(current.pending.map((p) => p.id), ['mine']);
    });
  });

  testWidgets(
    'вкладка без связи: подсказка, своя «ожидает отправки», «Добавить»',
    (tester) async {
      final repo = _MockRepo();
      final mine = ProblemRecord(
        id: 'mine',
        createdAt: DateTime.now(),
        createdBy: '',
        cellAddress: 'M1-4-3-2',
        reason: 'breakage',
        fromWarehouse: 'Основной',
        toWarehouse: 'Брак',
        pending: true,
      );
      when(() => repo.current()).thenAnswer(
        (_) async =>
            CurrentProblems(pending: [mine], failure: const Failure.network()),
      );
      final cubit = CurrentProblemsCubit(repo);
      var added = 0;
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(body: CurrentProblemsView(onAdd: () => added++)),
          ),
        ),
      );
      await cubit.load();
      await tester.pumpAndSettle();

      expect(find.text(t.problems.currentOnlineOnly), findsOneWidget);
      expect(find.text(t.problems.pendingSend), findsOneWidget);
      await tester.tap(find.text(t.problems.add));
      expect(added, 1);
      await cubit.close();
    },
  );
}
