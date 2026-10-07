import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:craft_wms/features/tasks/data/tasks_repository.dart';
import 'package:craft_wms/features/tasks/presentation/bloc/current_tasks_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'tasks_fixtures.dart';

class _MockRepo extends Mock implements TasksRepository {}

/// Вкладка «Текущие» (P5-02-1).
void main() {
  test('неудачное обновление не прячет уже показанный список', () async {
    // Урок долга 11: кладовщик не должен терять то, что уже видел, из-за неудачного запроса.
    final repo = _MockRepo();
    when(() => repo.current()).thenAnswer(
      (_) async => Right((
        tasks: [serverTask()],
        fromCache: false,
        syncedAt: DateTime.now(),
      )),
    );
    final cubit = CurrentTasksCubit(repo);
    await cubit.load();

    when(
      () => repo.current(),
    ).thenAnswer((_) async => const Left(Failure.server(500)));
    await cubit.load();

    expect(cubit.state.status, CurrentTasksStatus.loaded);
    expect(cubit.state.tasks, hasLength(1));
    await cubit.close();
  });

  test('список из снимка помечен — кладовщик видит, что связи нет', () async {
    final repo = _MockRepo();
    final at = DateTime(2026, 10, 7, 9);
    when(() => repo.current()).thenAnswer(
      (_) async =>
          Right((tasks: [serverTask()], fromCache: true, syncedAt: at)),
    );
    final cubit = CurrentTasksCubit(repo);

    await cubit.load();

    expect(cubit.state.fromCache, isTrue);
    expect(cubit.state.syncedAt, at);
    await cubit.close();
  });

  test('фильтр по виду работает и над снимком без связи', () async {
    final repo = _MockRepo();
    when(() => repo.current()).thenAnswer(
      (_) async => Right((
        tasks: [serverTask()],
        fromCache: true,
        syncedAt: DateTime.now(),
      )),
    );
    final cubit = CurrentTasksCubit(repo);
    await cubit.load();

    cubit.setKind('stocktake');
    expect(cubit.state.visible, isEmpty);
    cubit.setKind(TaskKind.putaway);
    expect(cubit.state.visible, hasLength(1));
    cubit.setKind(null);
    expect(cubit.state.visible, hasLength(1));

    // Обновление списка фильтр не сбрасывает.
    cubit.setKind('stocktake');
    await cubit.load();
    expect(cubit.state.visible, isEmpty);
    await cubit.close();
  });
}
