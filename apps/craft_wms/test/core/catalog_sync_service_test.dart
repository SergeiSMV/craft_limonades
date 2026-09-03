import 'dart:async';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/sync/catalog_sync_service.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';

class _MockApi extends Mock implements CatalogApi {}

/// Обновление справочников (P2-02) и его наблюдаемое состояние (ADHOC-10).
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late _MockApi api;
  late CatalogSyncService sync;

  const good = Good(id: 'g1', name: 'Товар', uom: 'шт');

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    api = _MockApi();
    sync = CatalogSyncService(api, cache, Talker());
  });

  tearDown(() => db.close());

  /// Ответы, при которых обновление проходит целиком.
  void stubHappyPath() {
    when(() => api.listAllGoods()).thenAnswer((_) async => const Right([good]));
    when(
      () => api.listGroups(),
    ).thenAnswer((_) async => const Right(<NomenclatureGroup>[]));
    when(
      () => api.listSuppliers(query: any(named: 'query')),
    ).thenAnswer((_) async => const Right(<Supplier>[]));
    when(
      () => api.listAllCells(warehouseId: any(named: 'warehouseId')),
    ).thenAnswer((_) async => const Right(<Cell>[]));
    when(
      () => api.listAllBarcodes(),
    ).thenAnswer((_) async => const Right(<BarcodeLink>[]));
  }

  test('успешное обновление сообщает, что справочники перечитаны', () async {
    stubHappyPath();

    final res = await sync.refresh();

    expect(res.right, SyncOutcome.refreshed);
    expect(sync.isRunning, isFalse);
  });

  test('отказ сети остаётся отказом', () async {
    when(
      () => api.listAllGoods(),
    ).thenAnswer((_) async => const Left(Failure.network()));

    final res = await sync.refresh();

    expect(res.isLeft, isTrue);
    expect(sync.isRunning, isFalse, reason: 'флаг снимается и после неудачи');
  });

  // ADHOC-10: отказ «уже идёт» раньше возвращался как успех, и экран рапортовал
  // «Справочники обновлены» на нажатие, которое ничего не сделало.
  test('второй запуск во время обновления отличим от успеха', () async {
    final held = Completer<Either<Failure, List<Good>>>();
    stubHappyPath();
    when(() => api.listAllGoods()).thenAnswer((_) => held.future);

    final first = sync.refresh(); // повис на первом справочнике
    await Future<void>.delayed(Duration.zero);
    final second = await sync.refresh();

    expect(second.right, SyncOutcome.alreadyRunning);
    expect(
      second.right,
      isNot(SyncOutcome.refreshed),
      reason: 'нельзя выдавать отказ за обновление',
    );

    held.complete(const Right([good]));
    expect((await first).right, SyncOutcome.refreshed);
    verify(() => api.listAllGoods()).called(1);
  });

  // По этому значению экран рисует индикатор, поэтому важно, что оно наблюдаемое и
  // отражает состояние, а не только момент вызова.
  test('состояние обновления наблюдаемо и возвращается в покой', () async {
    final seen = <bool>[];
    sync.running.addListener(() => seen.add(sync.running.value));
    stubHappyPath();

    expect(sync.running.value, isFalse);
    await sync.refresh();

    expect(seen, [true, false]);
    expect(sync.running.value, isFalse);
  });

  test('состояние возвращается в покой и при неудаче', () async {
    when(
      () => api.listAllGoods(),
    ).thenAnswer((_) async => const Left(Failure.network()));

    await sync.refresh();

    expect(sync.running.value, isFalse);
  });
}
