import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockApi extends Mock implements CatalogApi {}

/// Фасад справочников: что берётся из кэша, что из сети и что происходит без сети (P2-02).
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late _MockApi api;
  late CatalogRepository repo;

  const good = Good(id: 'g1', code: '15567', name: 'Арахис Бекон', uom: 'шт');
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    api = _MockApi();
    repo = CatalogRepository(api, cache);
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

    test('без сети отвечаем «не привязан», а не ошибкой', () async {
      // С полным справочником в кэше это лучший доступный ответ: экран предложит выбрать
      // товар вручную, и проход склада не встанет.
      when(
        () => api.resolveGoodByBarcode('NEW'),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final res = await repo.resolveGoodByBarcode('NEW');
      expect(res.isRight, isTrue);
      expect(res.right, isNull);
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

  group('запись', () {
    test('успешная привязка сразу попадает в кэш', () async {
      // Иначе повторный скан того же ШК ушёл бы в сеть до следующей синхронизации.
      await cache.putGoods(const [good]);
      await cache.putBarcodes([]);
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Right(null));

      await repo.bindBarcode(goodId: 'g1', barcode: 'BOX');
      expect((await cache.goodByBarcode('BOX'))?.id, 'g1');
    });

    test('неудачная привязка кэш не трогает', () async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([]);
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      await repo.bindBarcode(goodId: 'g1', barcode: 'BOX');
      expect(await cache.goodByBarcode('BOX'), isNull);
    });

    test('успешная отвязка убирает ШК из кэша', () async {
      await cache.putGoods(const [good]);
      await cache.putBarcodes([
        (barcode: 'ITEM', goodId: 'g1', symbology: null),
      ]);
      when(
        () => api.unbindBarcode(any()),
      ).thenAnswer((_) async => const Right(null));

      await repo.unbindBarcode('ITEM');
      expect(await cache.goodByBarcode('ITEM'), isNull);
    });
  });
}
