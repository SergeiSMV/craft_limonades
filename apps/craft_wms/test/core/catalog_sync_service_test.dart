import 'dart:async';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/problems/problem_reasons.dart';
import 'package:craft_wms/core/sync/catalog_sync_service.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../support/contents_stubs.dart';

class _MockApi extends Mock implements CatalogApi {}

class _MockWarehouses extends Mock implements InternalWarehouses {}

class _MockReasons extends Mock implements ProblemReasons {}

/// Обновление справочников (P2-02) и его наблюдаемое состояние (ADHOC-10).
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late _MockApi api;
  late CatalogSyncService sync;
  late FakeContentsSnapshotSync contents;
  late OutboxRepository outbox;
  late OutboxEffects effects;

  const good = Good(id: 'g1', name: 'Товар', uom: 'шт');

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    api = _MockApi();
    contents = FakeContentsSnapshotSync();
    final warehouses = _MockWarehouses();
    when(warehouses.refresh).thenAnswer((_) async => const Right(null));
    final reasons = _MockReasons();
    when(reasons.refresh).thenAnswer((_) async => const Right(null));
    outbox = OutboxRepository(db, const Uuid());
    effects = OutboxEffects(cache, contents, FakeTasksSnapshotSync());
    sync = CatalogSyncService(
      api,
      cache,
      contents,
      warehouses,
      reasons,
      outbox,
      effects,
      Talker(),
    );
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

  // P5-05: снимок содержимого склада грузится в том же заходе, последним, и его отказ —
  // отказ обновления: без него «Ячейка» и «Короб» без связи показывали бы старое.
  test('снимок содержимого грузится вместе со справочниками', () async {
    stubHappyPath();

    expect((await sync.refresh()).right, SyncOutcome.refreshed);
    expect(contents.refreshes, 1);

    contents.result = const Left(Failure.network());
    expect((await sync.refresh()).isLeft, isTrue);
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

  // ADHOC-36 (долг 23): загрузка справочников заменяет привязки целиком, а сервер ещё не знает
  // о том, что стоит в очереди. Привязка пропадала из кэша, отвязанный код возвращался.
  group('очередь поверх свежих привязок ШК', () {
    const barcode = '48513883';

    /// Поставить операцию в очередь вместе с её оптимистичным следствием — как репозиторий.
    Future<void> enqueue(OutboxKind kind) async {
      final payload = {'good_id': good.id, 'barcode': barcode};
      await outbox.enqueue(kind: kind, payload: payload);
      await effects.applyOptimistic(kind: kind, payload: payload);
    }

    test('неотправленная привязка переживает загрузку справочников', () async {
      stubHappyPath(); // сервер привязки ещё не знает
      await enqueue(OutboxKind.bindBarcode);

      expect((await sync.refresh()).right, SyncOutcome.refreshed);

      final codes = await cache.barcodesOfGood(good.id);
      expect(codes.map((b) => b.barcode), [barcode]);
      expect(codes.single.pending, isTrue, reason: 'всё ещё ждёт сервера');
    });

    test('неотправленная отвязка не возвращает код из справочника', () async {
      stubHappyPath();
      when(() => api.listAllBarcodes()).thenAnswer(
        (_) async => const Right([BarcodeLink(barcode: barcode, goodId: 'g1')]),
      );
      await cache.addBarcode(barcode: barcode, goodId: good.id);
      await enqueue(OutboxKind.unbindBarcode);

      expect((await sync.refresh()).right, SyncOutcome.refreshed);

      expect(await cache.barcodesOfGood(good.id), isEmpty);
    });

    test('без очереди справочник ложится как есть', () async {
      stubHappyPath();
      when(() => api.listAllBarcodes()).thenAnswer(
        (_) async => const Right([BarcodeLink(barcode: barcode, goodId: 'g1')]),
      );

      await sync.refresh();

      final codes = await cache.barcodesOfGood(good.id);
      expect(codes.single.pending, isFalse);
    });
  });
}
