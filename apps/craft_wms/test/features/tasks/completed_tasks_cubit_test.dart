import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:craft_wms/features/tasks/data/tasks_repository.dart';
import 'package:craft_wms/features/tasks/presentation/bloc/completed_tasks_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'tasks_fixtures.dart';

class _MockRepo extends Mock implements TasksRepository {}

/// Лента «Завершённые» (P5-02-1): подгрузка курсором и раскладка по дням.
void main() {
  setUpAll(() {
    registerFallbackValue(const CompletedFilter());
  });

  List<CompletedTask> page(int n, {int from = 0}) => [
    for (var i = from; i < from + n; i++)
      completed(
        't$i',
        '2026-10-07T10:${(59 - i % 60).toString().padLeft(2, '0')}:00Z',
      ),
  ];

  group('подгрузка', () {
    test(
      'следующая страница запрашивается после последней показанной записи',
      () async {
        final repo = _MockRepo();
        final first = page(CompletedTasksCubit.pageSize);
        when(
          () => repo.completed(
            filter: any(named: 'filter'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => Right(first));
        when(
          () => repo.completed(
            filter: any(named: 'filter'),
            after: first.last,
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => Right(page(2, from: 100)));
        final cubit = CompletedTasksCubit(repo);

        await cubit.load();
        expect(cubit.state.hasMore, isTrue);
        await cubit.loadMore();

        expect(cubit.state.items, hasLength(CompletedTasksCubit.pageSize + 2));
        expect(
          cubit.state.hasMore,
          isFalse,
          reason: 'короткая страница — конец ленты',
        );
        await cubit.close();
      },
    );

    test('неудача подгрузки не роняет показанную ленту', () async {
      final repo = _MockRepo();
      final first = page(CompletedTasksCubit.pageSize);
      when(
        () => repo.completed(
          filter: any(named: 'filter'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => Right(first));
      when(
        () => repo.completed(
          filter: any(named: 'filter'),
          after: first.last,
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final cubit = CompletedTasksCubit(repo);

      await cubit.load();
      await cubit.loadMore();

      expect(cubit.state.status, CompletedStatus.loaded);
      expect(cubit.state.items, hasLength(CompletedTasksCubit.pageSize));
      expect(cubit.state.loadingMore, isFalse);
      await cubit.close();
    });

    test(
      'без связи лента говорит об ошибке, а не показывает пустоту',
      () async {
        final repo = _MockRepo();
        when(
          () => repo.completed(
            filter: any(named: 'filter'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => const Left(Failure.network()));
        final cubit = CompletedTasksCubit(repo);

        await cubit.load();

        expect(cubit.state.status, CompletedStatus.error);
        expect(cubit.state.failure, isA<NetworkFailure>());
        await cubit.close();
      },
    );
  });

  group('раскладка по дням', () {
    test('разделитель стоит перед первой записью каждого дня', () {
      final items = [
        completed('a', DateTime(2026, 10, 7, 15).toUtc().toIso8601String()),
        completed('b', DateTime(2026, 10, 7, 9).toUtc().toIso8601String()),
        completed('c', DateTime(2026, 10, 6, 18).toUtc().toIso8601String()),
      ];

      final entries = groupByDay(items);

      expect(entries.map((e) => e.runtimeType).toList(), [
        FeedDay,
        FeedTask,
        FeedTask,
        FeedDay,
        FeedTask,
      ]);
      expect((entries[0] as FeedDay).day, DateTime(2026, 10, 7));
      expect((entries[3] as FeedDay).day, DateTime(2026, 10, 6));
    });
  });
}
