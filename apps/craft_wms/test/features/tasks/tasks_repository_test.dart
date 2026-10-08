import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/tasks/data/tasks_api.dart';
import 'package:craft_wms/features/tasks/data/tasks_cache.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:craft_wms/features/tasks/data/tasks_repository.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'tasks_fixtures.dart';

class _MockApi extends Mock implements TasksApi {}

/// Текущие задания (P5-02-1): удачный ответ обновляет снимок, без связи отдаётся снимок.
void main() {
  late AppDatabase db;
  late _MockApi api;
  late TasksRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    api = _MockApi();
    repo = TasksRepository(api, TasksCache(db));
  });
  tearDown(() => db.close());

  test(
    'ответ сервера разбирается целиком: короб с составом и россыпь с остатком',
    () {
      final task = serverTask();
      expect(task.number, 57);
      expect(task.items.first.isBox, isTrue);
      expect(task.items.first.contents.single.qty, '12');
      expect(task.items.last.remaining, '3');
      expect(task.openItems, 2);
    },
  );

  test(
    'без связи отдаётся снимок последнего ответа — с позициями и составом',
    () async {
      when(() => api.current()).thenAnswer((_) async => Right([serverTask()]));
      final online = await repo.current();
      expect(online.right.fromCache, isFalse);

      when(
        () => api.current(),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final offline = await repo.current();

      expect(offline.isRight, isTrue);
      expect(offline.right.fromCache, isTrue);
      expect(offline.right.syncedAt, isNotNull);
      // Снимок обязан пережить запись и чтение без потерь — по нему задание выполняется офлайн.
      expect(offline.right.tasks.single, serverTask());
    },
  );

  test('без связи и без снимка — «нет связи», а не пустой список', () async {
    when(
      () => api.current(),
    ).thenAnswer((_) async => const Left(Failure.network()));

    final res = await repo.current();

    expect(res.left, isA<NetworkFailure>());
  });

  test(
    'новый ответ заменяет снимок целиком: ушедшее задание из него пропадает',
    () async {
      when(() => api.current()).thenAnswer((_) async => Right([serverTask()]));
      await repo.current();
      when(
        () => api.current(),
      ).thenAnswer((_) async => const Right(<WarehouseTask>[]));
      await repo.current();

      when(
        () => api.current(),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final offline = await repo.current();

      // Пустой снимок — это «заданий нет», а не «нет связи»: список был получен.
      expect(offline.isRight, isTrue);
      expect(offline.right.tasks, isEmpty);
    },
  );

  test('отказ сервера снимком не подменяется', () async {
    when(() => api.current()).thenAnswer((_) async => Right([serverTask()]));
    await repo.current();
    when(
      () => api.current(),
    ).thenAnswer((_) async => const Left(Failure.server(500)));

    final res = await repo.current();

    expect(res.left, isA<ServerFailure>());
  });

  test(
    'счётчик для плитки следует за снимком, в том числе за пустым',
    () async {
      final counts = <int>[];
      final sub = repo.watchCurrentCount().listen(counts.add);
    await pumpEventQueue(); // первое значение — до любого снимка

      when(() => api.current()).thenAnswer((_) async => Right([serverTask()]));
      await repo.current();
      await pumpEventQueue();
      when(
        () => api.current(),
      ).thenAnswer((_) async => const Right(<WarehouseTask>[]));
      await repo.current();
      await pumpEventQueue();
      await sub.cancel();

      // До первого снимка — 0, затем 1, затем снова 0: задание ушло из текущих.
      expect(counts.first, 0);
      expect(counts, containsAllInOrder([1, 0]));
    },
  );

  test('ответ сервера с журналом разбирается', () {
    final ev = TaskEvent.fromJson(const {
      'event': 'intercepted',
      'user': 'Второй',
      'prev_user': 'Кладовщик',
      'at': '2026-10-07T12:00:00Z',
    });
    expect(ev.event, TaskEventKind.intercepted);
    expect(ev.prevUser, 'Кладовщик');
    expect(ev.putawayId, isNull);
  });
}
