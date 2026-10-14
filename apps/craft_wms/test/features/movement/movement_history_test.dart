import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/movement/data/movement_history_repository_impl.dart';
import 'package:craft_wms/features/movement/domain/movement_history.dart';
import 'package:craft_wms/features/movement/domain/movement_models.dart';
import 'package:craft_wms/features/movement/presentation/bloc/movement_history_cubit.dart';
import 'package:craft_wms/features/movement/presentation/widgets/move_lines_list.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements MovementHistoryRepository {}

MoveRecord record(String id, String postedAt) => MoveRecord(
  id: id,
  kind: 'move',
  postedAt: postedAt,
  executor: const MoveUser(id: 'u1', fullName: 'Иванов Иван'),
  loadUnits: 1,
  goods: 2,
);

/// ADHOC-28: история перемещений всего склада — разбор ответа сервера, лента с подгрузкой
/// и фильтром, строки записи только для чтения.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocaleSettings.useDeviceLocale);
  setUpAll(() {
    registerFallbackValue(const MoveHistoryQuery());
  });

  group('разбор ответа сервера', () {
    test('запись ленты: исполнитель, счёт строк, момент как курсор', () {
      final r = recordFromJson({
        'id': 'm1',
        'kind': 'move',
        'posted_at': '2026-10-14T09:12:30.123456789Z',
        'executor': {'id': 'u1', 'full_name': 'Иванов Иван'},
        'load_units': 1,
        'goods': 2,
      });
      expect(r.executor.fullName, 'Иванов Иван');
      expect((r.loadUnits, r.goods), (1, 2));
      expect(
        r.postedAt,
        '2026-10-14T09:12:30.123456789Z',
        reason: 'курсор уходит на сервер до наносекунд, как пришёл',
      );
    });

    test(
      'строка: короб целиком и товар из короба в россыпь — строкой сеанса',
      () {
        final box = lineFromJson({
          'load_unit_id': 'lu1',
          'from': {'cell_id': 'c1', 'cell_address': 'M1-5-3-3'},
          'to': {'cell_id': 'c2', 'cell_address': 'M1-5-4-1'},
        });
        expect(box.isWholeBox, isTrue);
        expect(box.to.cellAddress, 'M1-5-4-1');

        final goods = lineFromJson({
          'good': {'id': 'g1', 'code': '16121', 'name': 'Кальмар', 'uom': 'шт'},
          'production_date': '01-09-2026',
          'qty': '4',
          'from': {
            'cell_id': 'c1',
            'cell_address': 'M1-5-3-3',
            'load_unit_id': 'lu1',
          },
          'to': {'cell_id': 'c1', 'cell_address': 'M1-5-3-3'},
        });
        expect(goods.isWholeBox, isFalse);
        expect(goods.qty, 4, reason: 'сервер отдаёт десятичное текстом');
        expect(goods.good?.name, 'Кальмар');
        expect(goods.from.isBox, isTrue);
        expect(goods.to.isBox, isFalse);
      },
    );
  });

  group('лента', () {
    List<MoveRecord> page(int n, {int from = 0}) => [
      for (var i = from; i < from + n; i++)
        record(
          'm$i',
          '2026-10-14T10:${(59 - i % 60).toString().padLeft(2, '0')}:00Z',
        ),
    ];

    test('следующая страница — после последней показанной записи', () async {
      final repo = _MockRepo();
      final first = page(MovementHistoryCubit.pageSize);
      when(
        () => repo.page(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => Right(first));
      when(
        () => repo.page(
          query: any(named: 'query'),
          after: first.last,
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => Right(page(2, from: 100)));
      final cubit = MovementHistoryCubit(repo);

      await cubit.load();
      expect(cubit.state.hasMore, isTrue);
      await cubit.loadMore();

      expect(cubit.state.items, hasLength(MovementHistoryCubit.pageSize + 2));
      expect(cubit.state.hasMore, isFalse, reason: 'короткая страница — конец');
      await cubit.close();
    });

    test(
      'фильтр уходит на сервер отдельным запросом и сбрасывает ленту',
      () async {
        final repo = _MockRepo();
        when(
          () => repo.page(
            query: any(named: 'query'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => Right(page(1)));
        final cubit = MovementHistoryCubit(repo);

        await cubit.setFilter(
          CompletedFilter(
            from: DateTime(2026, 10, 1),
            to: DateTime(2026, 10, 14),
            executor: const TaskUser(id: 'u2', fullName: 'Петров'),
          ),
        );

        final q =
            verify(
                  () => repo.page(
                    query: captureAny(named: 'query'),
                    limit: any(named: 'limit'),
                  ),
                ).captured.single
                as MoveHistoryQuery;
        expect(q.executorId, 'u2');
        expect((q.from, q.to), (DateTime(2026, 10, 1), DateTime(2026, 10, 14)));
        expect(cubit.state.filter.activeCount, 2);
        await cubit.close();
      },
    );

    test('нет связи — ошибка сети, лента не хранится офлайн', () async {
      final repo = _MockRepo();
      when(
        () => repo.page(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final cubit = MovementHistoryCubit(repo);

      await cubit.load();

      expect(cubit.state.status, HistoryStatus.error);
      expect(cubit.state.failure, isA<NetworkFailure>());
      await cubit.close();
    });

    test('исполнители — для общего листа фильтра', () async {
      final repo = _MockRepo();
      when(() => repo.executors()).thenAnswer(
        (_) async => const Right([MoveUser(id: 'u1', fullName: 'Иванов Иван')]),
      );
      final cubit = MovementHistoryCubit(repo);

      await cubit.loadExecutors();

      expect(cubit.state.executors, [
        const TaskUser(id: 'u1', fullName: 'Иванов Иван'),
      ]);
      await cubit.close();
    });

    test('по дням: разделитель перед первой записью дня', () {
      final entries = groupHistoryByDay([
        record('a', '2026-10-14T12:00:00'),
        record('b', '2026-10-14T09:00:00'),
        record('c', '2026-10-13T18:00:00'),
      ]);
      expect(entries.map((e) => e is HistoryDay ? 'день' : 'запись'), [
        'день',
        'запись',
        'запись',
        'день',
        'запись',
      ]);
    });
  });

  testWidgets('строки записи — по порядку проведения и без «Убрать»', (
    tester,
  ) async {
    const a = MovePlace(cellId: 'c1', cellAddress: 'M1-5-3-3');
    const b = MovePlace(cellId: 'c2', cellAddress: 'M1-5-4-1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveLinesList(
            lines: const [
              MoveLine(
                loadUnitId: '11111111-0000-4000-8000-000000000001',
                from: a,
                to: b,
              ),
              MoveLine(
                loadUnitId: '22222222-0000-4000-8000-000000000002',
                from: b,
                to: a,
              ),
            ],
            title: t.movement.recordLines,
            newestFirst: false,
          ),
        ),
      ),
    );

    expect(find.text(t.movement.recordLines), findsOneWidget);
    expect(find.byTooltip(t.movement.removeLine), findsNothing);
    final routes = tester
        .widgetList<Text>(find.textContaining('→'))
        .map((w) => w.data)
        .toList();
    expect(routes, [
      t.movement.lineRoute(from: 'M1-5-3-3', to: 'M1-5-4-1'),
      t.movement.lineRoute(from: 'M1-5-4-1', to: 'M1-5-3-3'),
    ]);
  });
}
