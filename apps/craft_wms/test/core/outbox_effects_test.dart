import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../support/outbox_stubs.dart';
import '../support/contents_stubs.dart';

class _MockApi extends Mock implements CatalogApi {}

class _MockConnectivity extends Mock implements Connectivity {}

/// Локальные следствия операций очереди (P2-06).
///
/// Найдено на устройстве: кладовщик привязал ШК офлайн, включил Wi-Fi, список
/// несинхронизированного очистился — а в карточке товара штрихкода не оказалось. Кэш обновлял
/// только путь немедленной отправки; движок синхронизации отправлял мимо него, и локальное
/// состояние оставалось прежним до следующей полной синхронизации справочников.
void main() {
  setUpAll(registerOutboxFallbacks);
  late AppDatabase db;
  late CatalogCache cache;
  late OutboxRepository outbox;
  late OutboxEffects effects;
  late _MockApi api;
  late MockOperationsApi opsApi;
  late SyncEngine engine;
  late CatalogRepository repo;

  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');
  const barcode = '48513883';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    outbox = OutboxRepository(db, const Uuid());
    effects = OutboxEffects(cache, FakeContentsSnapshotSync());
    api = _MockApi();
    opsApi = MockOperationsApi();
    engine = SyncEngine(
      outbox,
      OutboxSender(opsApi),
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
      stubBatchFailure(opsApi, const Failure.network());

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
      stubBatchOutcome(opsApi, OperationOutcome.accepted);

      await repo.bindBarcode(goodId: good.id, barcode: barcode);

      expect((await cached()).single.pending, isFalse);
    });

    // Главный сценарий находки: связь появилась, очередь ушла — и кэш обязан догнать.
    test('отложенная привязка снимает пометку, когда уходит движком', () async {
      stubBatchFailure(opsApi, const Failure.network());
      await repo.bindBarcode(goodId: good.id, barcode: barcode);
      expect((await cached()).single.pending, isTrue);

      stubBatchOutcome(opsApi, OperationOutcome.accepted);
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

    // Повтор уже применённой операции (P2-05): сервер отвечает duplicate, и это УСПЕХ.
    //
    // Случай не выдуманный: попытка оборвалась после того, как сервер её применил, — процесс
    // умер, ответ не дошёл, статус остался `sending`, и очередь шлёт операцию снова. Прими мы
    // duplicate за отказ, привязка откатилась бы из карточки, хотя на сервере она есть.
    test('duplicate подтверждает привязку, а не откатывает её', () async {
      stubBatchFailure(opsApi, const Failure.network());
      await repo.bindBarcode(goodId: good.id, barcode: barcode);
      expect((await cached()).single.pending, isTrue);

      stubBatchOutcome(opsApi, OperationOutcome.duplicate);
      await engine.drain();

      final rows = await cached();
      expect(
        rows,
        hasLength(1),
        reason: 'операция применена — привязка на месте',
      );
      expect(
        rows.single.pending,
        isFalse,
        reason: 'повтор подтверждает: ждать больше нечего',
      );
      expect(await outbox.pendingCount(), 0);
      expect(
        await outbox.watchRejected().first,
        isEmpty,
        reason: 'успешная работа не должна попадать на экран разбора',
      );
    });

    // Это и есть «локальный откат» из критерия P2-06.
    test('отказ по существу откатывает привязку', () async {
      stubBatchOutcome(
        opsApi,
        OperationOutcome.rejected,
        error: 'barcode bound to another good',
      );

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
      stubBatchFailure(opsApi, const Failure.network());

      await repo.unbindBarcode(goodId: good.id, barcode: barcode);

      expect(await cached(), isEmpty);
    });

    // Товар кладётся в тело операции не для сервера — ему он не нужен, — а чтобы было чем
    // вернуть привязку при отказе.
    test('отказ по существу возвращает привязку на место', () async {
      stubBatchOutcome(
        opsApi,
        OperationOutcome.rejected,
        error: 'barcode bound to another good',
      );

      await repo.unbindBarcode(goodId: good.id, barcode: barcode);

      final rows = await cached();
      expect(rows, hasLength(1));
      expect(rows.single.barcode, barcode);
    });
  });

  // Схема поднялась до версии 3: у привязки появилась пометка «ещё не подтверждена».
  // P5-05: подтверждённая приёмка или размещение устаревают снимок содержимого склада.
  test('подтверждение приёмки и размещения просит обновить снимок', () async {
    final contents = FakeContentsSnapshotSync();
    final e = OutboxEffects(cache, contents);
    final now = DateTime(2026, 10, 8);
    OutboxOperation op(OutboxKind kind) => OutboxOperation(
      seq: 1,
      operationId: 'op',
      kind: kind,
      payload: const {'barcode': barcode, 'good_id': 'g1'},
      status: OutboxStatus.sent,
      attempts: 1,
      createdAt: now,
      updatedAt: now,
    );

    await e.confirm(op(OutboxKind.receiptSubmit));
    await e.confirm(op(OutboxKind.putawaySubmit));
    await e.confirm(op(OutboxKind.bindBarcode));

    expect(contents.requests, 2);
  });

  test('миграция 2 → 3 добавляет пометку, не трогая привязки', () async {
    await cache.addBarcode(barcode: barcode, goodId: good.id);
    await db.customStatement('ALTER TABLE cached_barcodes DROP COLUMN pending');
    // Шаги миграции идут от `from` до текущей версии, а флага дефолтной ячейки (схема 5)
    // в старой схеме тоже не было.
    await db.customStatement('ALTER TABLE cached_cells DROP COLUMN is_default');

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
