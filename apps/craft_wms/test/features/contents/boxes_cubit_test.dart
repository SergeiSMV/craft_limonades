import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/presentation/bloc/boxes_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contents_stubs.dart';

/// Вкладка «Короба» (P5-05-1): открытие обновляет снимок, поиск — по приведённому коду.
void main() {
  late FakeContentsRepository repo;
  late FakeContentsSnapshotSync snapshot;
  late BoxesCubit cubit;

  const a = LoadUnitView(
    id: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
    live: true,
  );
  const b = LoadUnitView(
    id: '11111111-2222-4333-8444-555566667777',
    live: true,
  );

  setUp(() {
    repo = FakeContentsRepository()..units = const [a, b];
    snapshot = FakeContentsSnapshotSync();
    cubit = BoxesCubit(repo, snapshot);
  });

  tearDown(() => cubit.close());

  test(
    'первое открытие обновляет снимок и показывает все короба; повторное — нет',
    () async {
      await cubit.open();
      expect(snapshot.refreshes, 1);
      expect(cubit.state.status, BoxesStatus.ready);
      expect(cubit.state.data!.value, hasLength(2));

      await cubit.open();
      expect(snapshot.refreshes, 1);
    },
  );

  test('код с ярлыка ищется приведённым: без пробела, заглавными', () async {
    await cubit.open();
    await cubit.submitQuery('9fa0 b1c2');

    expect(repo.searches, ['9FA0B1C2']);
    expect(cubit.state.data!.value!.single.id, a.id);
  });

  test('не код — подсказка, сервер не спрашиваем', () async {
    await cubit.open();
    await cubit.submitQuery('кальмар');

    expect(cubit.state.invalidQuery, isTrue);
    expect(repo.searches, isEmpty);
  });

  test('набор ищет после паузы, а не на каждый знак', () async {
    await cubit.open();
    cubit.setQueryDebounced('9');
    cubit.setQueryDebounced('9f');
    cubit.setQueryDebounced('9fa0');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(repo.searches, ['9FA0']);
  });

  test('пустая строка — снова весь список', () async {
    await cubit.open();
    await cubit.submitQuery('9fa0');
    await cubit.submitQuery('');

    expect(cubit.state.searching, isFalse);
    expect(cubit.state.data!.value, hasLength(2));
  });

  test('без связи снимок не обновился — подпись «данные на»', () async {
    snapshot.result = const Left(Failure.network());
    repo.unitsFreshness = FromSnapshot(DateTime(2026, 10, 8, 14, 30));

    await cubit.open();
    expect(cubit.state.data!.freshness, isA<FromSnapshot>());
  });
}
