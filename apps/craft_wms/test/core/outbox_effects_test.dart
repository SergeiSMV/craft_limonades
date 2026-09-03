import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста.
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

class _MockApi extends Mock implements CatalogApi {}

class _MockConnectivity extends Mock implements Connectivity {}

/// Локальные следствия операций очереди (P2-06).
///
/// Найдено на устройстве: кладовщик привязал ШК офлайн, включил Wi-Fi, список
/// несинхронизированного очистился — а в карточке товара штрихкода не оказалось. Кэш обновлял
/// только путь немедленной отправки; движок синхронизации отправлял мимо него, и локальное
/// состояние оставалось прежним до следующей полной синхронизации справочников.
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late OutboxRepository outbox;
  late OutboxEffects effects;
  late _MockApi api;
  late SyncEngine engine;
  late CatalogRepository repo;

  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');
  const barcode = '48513883';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    outbox = OutboxRepository(db, const Uuid());
    effects = OutboxEffects(cache);
    api = _MockApi();
    engine = SyncEngine(
      outbox,
      OutboxSender(api),
      effects,
      Talker(),
      _MockConnectivity(),
    );
    repo = CatalogRepository(api, cache, outbox, effects, engine);
    await cache.putGoods(const [good]);
    await cache.putBarcodes([]);
  });

  tearDown(() => db.close());

  /// Привязки товара в локальном кэше.
  Future<List<Barcode>> cached() => cache.barcodesOfGood(good.id);

  group('привязка', () {
    test('без связи ШК виден сразу, но помечен как неподтверждённый', () async {
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.network()));

      await repo.bindBarcode(goodId: good.id, barcode: barcode);

      final rows = await cached();
      expect(rows, hasLength(1), reason: 'кладовщик видит результат сразу');
      expect(rows.single.barcode, barcode);
      expect(
        rows.single.pending,
        isTrue,
        reason: 'сервер её ещё не подтвердил',
      );
    });

    test('успешная привязка подтверждается сразу', () async {
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Right(null));

      await repo.bindBarcode(goodId: good.id, barcode: barcode);

      expect((await cached()).single.pending, isFalse);
    });

    // Главный сценарий находки: связь появилась, очередь ушла — и кэш обязан догнать.
    test('отложенная привязка снимает пометку, когда уходит движком', () async {
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.network()));
      await repo.bindBarcode(goodId: good.id, barcode: barcode);
      expect((await cached()).single.pending, isTrue);

      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Right(null));
      await engine.drain();

      final rows = await cached();
      expect(rows, hasLength(1), reason: 'привязка на месте');
      expect(
        rows.single.pending,
        isFalse,
        reason: 'сервер подтвердил — пометке больше нечего ждать',
      );
      expect(await outbox.pendingCount(), 0);
    });

    // Это и есть «локальный откат» из критерия P2-06.
    test('отказ по существу откатывает привязку', () async {
      when(
        () => api.bindBarcode(
          goodId: any(named: 'goodId'),
          barcode: any(named: 'barcode'),
        ),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      await repo.bindBarcode(goodId: good.id, barcode: barcode);

      expect(
        await cached(),
        isEmpty,
        reason: 'иначе отклонённая привязка осталась бы в карточке навсегда',
      );
      expect(await outbox.watchRejected().first, hasLength(1));
    });
  });

  group('отвязка', () {
    setUp(() => cache.addBarcode(barcode: barcode, goodId: good.id));

    test('без связи ШК исчезает из карточки сразу', () async {
      when(
        () => api.unbindBarcode(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));

      await repo.unbindBarcode(goodId: good.id, barcode: barcode);

      expect(await cached(), isEmpty);
    });

    // Товар кладётся в тело операции не для сервера — ему он не нужен, — а чтобы было чем
    // вернуть привязку при отказе.
    test('отказ по существу возвращает привязку на место', () async {
      when(
        () => api.unbindBarcode(any()),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      await repo.unbindBarcode(goodId: good.id, barcode: barcode);

      final rows = await cached();
      expect(rows, hasLength(1));
      expect(rows.single.barcode, barcode);
    });
  });

  // Схема поднялась до версии 3: у привязки появилась пометка «ещё не подтверждена».
  test('миграция 2 → 3 добавляет пометку, не трогая привязки', () async {
    await cache.addBarcode(barcode: barcode, goodId: good.id);
    await db.customStatement('ALTER TABLE cached_barcodes DROP COLUMN pending');

    await db.migration.onUpgrade(Migrator(db), 2, 3);

    final rows = await cached();
    expect(rows, hasLength(1), reason: 'привязки на месте');
    expect(
      rows.single.pending,
      isFalse,
      reason: 'уже лежавшие привязки принёс сервер — они подтверждённые',
    );
  });
}
