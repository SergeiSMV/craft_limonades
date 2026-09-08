import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../support/outbox_stubs.dart';

class _MockApi extends Mock implements CatalogApi {}

class _MockConnectivity extends Mock implements Connectivity {}

/// Фасад справочников: что берётся из кэша, что из сети и что происходит без сети (P2-02).
void main() {
  setUpAll(registerOutboxFallbacks);
  late AppDatabase db;
  late CatalogCache cache;
  late _MockApi api;
  late MockOperationsApi opsApi;
  late OutboxRepository outbox;
  late CatalogRepository repo;

  const good = Good(id: 'g1', code: '15567', name: 'Арахис Бекон', uom: 'шт');
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    api = _MockApi();
    opsApi = MockOperationsApi();
    outbox = OutboxRepository(db, const Uuid());
    final effects = OutboxEffects(cache);
    // Движок в тесте настоящий: отправка идёт через него, и проверять надо именно тот путь,
    // которым операция уходит на самом деле.
    final engine = SyncEngine(
      outbox,
      OutboxSender(opsApi),
      effects,
      Talker(),
      _MockConnectivity(),
    );
    repo = CatalogRepository(api, cache, outbox, effects, engine);
  });

  tearDown(() => db.close());

  group('пустой кэш', () {
    test('до первой синхронизации читает из сети', () async {
      when(
        () => api.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(
        (_) async => const Right(
          Paged<Good>(items: [good], total: 1, limit: 50, offset: 0),
        ),
      );

      final res = await repo.listGoods();
      expect(res.right.items.single.id, 'g1');
      verify(
        () => api.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).called(1);
    });
  });

  group('заполненный кэш', () {
    setUp(() async {
      await cache.putGoods(const [good]);
      await cache.putCells(const [cell]);
    });

    test('товары читаются из кэша, сеть не трогается', () async {
      final res = await repo.listGoods(query: 'арахис');
      expect(res.right.items.single.id, 'g1');
      verifyNever(
        () => api.listGoods(
          query: any(named: 'query'),
          groupId: any(named: 'groupId'),
          supplierId: any(named: 'supplierId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      );
    });

    test(
      'ячейки читаются из кэша — тех самых четырёх запросов больше нет',
      () async {
        final res = await repo.listAllCells();
        expect(res.right.single.address, 'M1-1-1-1');
        verifyNever(
          () => api.listAllCells(warehouseId: any(named: 'warehouseId')),
        );
      },
    );

    test('остатки идут в сеть ВСЕГДА, даже при полном кэше', () async {
      // Остаток меняется от каждой операции любого терминала: кэшировать его нельзя.
      when(
        () => api.listStock(
          goodId: any(named: 'goodId'),
          cellId: any(named: 'cellId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer(
        (_) async => const Right(
          Paged<StockItem>(items: [], total: 0, limit: 200, offset: 0),
        ),
      );

      await repo.listStock(goodId: 'g1');
      verify(
        () => api.listStock(
          goodId: any(named: 'goodId'),
          cellId: any(named: 'cellId'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).called(1);
    });
  });

  group('готовность считается по каждому справочнику', () {
    test('ячейки из кэша, а ШК ещё из сети', () async {
      // Ровно та ситуация, что была на проде: выгрузки привязок ШК ещё нет, но ячейки уже есть.
      await cache.putCells(const [cell]);
      when(
        () => api.resolveGoodByBarcode(any()),
      ).thenAnswer((_) async => const Right(good));

      final cells = await repo.listAllCells();
      expect(cells.right, isNotEmpty);
      verifyNever(
        () => api.listAllCells(warehouseId: any(named: 'warehouseId')),
      );

      final resolved = await repo.resolveGoodByBarcode('4607044660205');
      expect(resolved.right?.id, 'g1');
      verify(() => api.resolveGoodByBarcode('4607044660205')).called(1);
    });
  });

  group('резолв по штрихкоду', () {
    setUp(() async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([
        (barcode: 'ITEM', goodId: 'g1', symbology: 'Code128'),
      ]);
    });

    test('известный ШК берётся из кэша без сети', () async {
      final res = await repo.resolveGoodByBarcode('ITEM');
      expect(res.right?.id, 'g1');
      verifyNever(() => api.resolveGoodByBarcode(any()));
    });

    test(
      'неизвестный ШК уточняется в сети — его мог привязать другой терминал',
      () async {
        when(
          () => api.resolveGoodByBarcode('NEW'),
        ).thenAnswer((_) async => const Right(good));
        final res = await repo.resolveGoodByBarcode('NEW');
        expect(res.right?.id, 'g1');
        verify(() => api.resolveGoodByBarcode('NEW')).called(1);
      },
    );

    test('без сети отвечаем ошибкой, а не «не привязан» (ADHOC-06)', () async {
      // Промах кэша офлайн неотличим от привязки, сделанной на другом терминале после нашей
      // синхронизации. Прежний ответ `Right(null)` выдавал догадку за факт, а по нему экран
      // предлагает привязать ШК — и привязка легла бы поверх уже существующей на сервере.
      when(
        () => api.resolveGoodByBarcode('NEW'),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final res = await repo.resolveGoodByBarcode('NEW');
      expect(res.isLeft, isTrue);
      expect(res.left, isA<NetworkFailure>());
    });

    test('ошибка сервера остаётся ошибкой', () async {
      // Отличать «не знаю» от «сервер сломался» важно: молчаливое «не привязан» на 500
      // спрятало бы поломку.
      when(
        () => api.resolveGoodByBarcode('NEW'),
      ).thenAnswer((_) async => const Left(Failure.server(500)));
      final res = await repo.resolveGoodByBarcode('NEW');
      expect(res.isLeft, isTrue);
    });
  });

  // P2-03: запись сперва ложится в очередь, и только потом уходит в сеть. Экран при этом
  // ведёт себя как раньше — исход возвращается вызывающему без изменений.
  group('очередь операций', () {
    setUp(() async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([]);
    });

    test('успешная привязка помечается отправленной', () async {
      stubBatchOutcome(opsApi, OperationOutcome.accepted);

      final res = await repo.bindBarcode(goodId: 'g1', barcode: 'NEW');

      expect(res.isRight, isTrue);
      expect(await outbox.pending(), isEmpty);
      expect(await outbox.pendingCount(), 0);
    });

    // Главное свойство очереди: операция, не ушедшая с первой попытки, остаётся делом,
    // а не исчезает вместе с неудачным вызовом.
    test(
      'операция без связи остаётся в очереди, ошибка доходит до экрана',
      () async {
        stubBatchFailure(opsApi, const Failure.network());

        final res = await repo.bindBarcode(goodId: 'g1', barcode: 'NEW');

        expect(
          res.isLeft,
          isTrue,
          reason: 'UX прежний: экран узнаёт о неудаче',
        );
        final pending = await outbox.pending();
        expect(pending, hasLength(1));
        expect(pending.single.kind, OutboxKind.bindBarcode);
        expect(pending.single.status, OutboxStatus.pending);
        expect(pending.single.attempts, 1);
        expect(pending.single.payload['barcode'], 'NEW');
      },
    );

    // 409 «ШК уже за другим товаром» повтором не лечится — сервер ответит тем же, а очередь
    // встанет намертво на неисполнимой операции.
    test('отказ по существу выводит операцию из очереди', () async {
      stubBatchOutcome(
        opsApi,
        OperationOutcome.rejected,
        error: 'barcode bound to another good',
      );

      final res = await repo.bindBarcode(goodId: 'g1', barcode: 'NEW');

      expect(res.isLeft, isTrue);
      expect(await outbox.pending(), isEmpty);
    });

    test('5xx считается временным и остаётся в очереди', () async {
      stubBatchFailure(opsApi, const Failure.server(503));

      await repo.bindBarcode(goodId: 'g1', barcode: 'NEW');

      expect(await outbox.pending(), hasLength(1));
    });

    test('отвязка тоже проходит через очередь', () async {
      stubBatchFailure(opsApi, const Failure.network());

      await repo.unbindBarcode(goodId: 'g1', barcode: 'ITEM');

      final pending = await outbox.pending();
      expect(pending.single.kind, OutboxKind.unbindBarcode);
      expect(pending.single.payload['barcode'], 'ITEM');
    });
  });

  group('запись', () {
    test('успешная привязка сразу попадает в кэш', () async {
      // Иначе повторный скан того же ШК ушёл бы в сеть до следующей синхронизации.
      await cache.putGoods(const [good]);
      await cache.putBarcodes([]);
      stubBatchOutcome(opsApi, OperationOutcome.accepted);

      await repo.bindBarcode(goodId: 'g1', barcode: 'BOX');
      expect((await cache.goodByBarcode('BOX'))?.id, 'g1');
    });

    test('неудачная привязка кэш не трогает', () async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([]);
      stubBatchOutcome(
        opsApi,
        OperationOutcome.rejected,
        error: 'barcode bound to another good',
      );

      await repo.bindBarcode(goodId: 'g1', barcode: 'BOX');
      expect(await cache.goodByBarcode('BOX'), isNull);
    });

    test('успешная отвязка убирает ШК из кэша', () async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([
        (barcode: 'ITEM', goodId: 'g1', symbology: null),
      ]);
      stubBatchOutcome(opsApi, OperationOutcome.accepted);

      await repo.unbindBarcode(goodId: 'g1', barcode: 'ITEM');
      expect(await cache.goodByBarcode('ITEM'), isNull);
    });
  });
}
