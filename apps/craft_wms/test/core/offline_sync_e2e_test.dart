import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/operations_api.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/sync/link_state.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../support/fake_operations_server.dart';
import '../support/contents_stubs.dart';

class _MockConnectivity extends Mock implements Connectivity {}

/// Сквозной сценарий офлайн-ядра: офлайн-действие → потеря связи → её возврат → данные на
/// сервере (P2-08, контрольная сборка всей фазы P2).
///
/// Собрано из НАСТОЯЩИХ частей: локальная база drift, очередь операций, кэш справочников,
/// движок синхронизации, отправщик, транспорт поверх настоящего dio. Подменён только сам
/// сервер — и подменён не заглушкой с заготовленным ответом, а фейком, который разбирает
/// присланный батч и ведёт свой дедуп по `operation_id`. Заглушка подтвердила бы любой формат
/// запроса, в том числе неверный; этот отвечает по тем же правилам, что проверенный HTTP-тест
/// бэкенда, поэтому расхождение форматов здесь видно.
void main() {
  late AppDatabase db;
  late CatalogCache cache;
  late OutboxRepository outbox;
  late OutboxEffects effects;
  late SyncEngine engine;
  late CatalogRepository repo;
  late FakeOperationsServer server;

  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');
  const otherGood = Good(id: 'g2', name: 'Кальмары', uom: 'шт');
  const code = '4607044662964';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    outbox = OutboxRepository(db, const Uuid());
    effects = OutboxEffects(
      cache,
      FakeContentsSnapshotSync(),
      FakeTasksSnapshotSync(),
    );

    server = FakeOperationsServer();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.test/api/v1/'))
      ..httpClientAdapter = server;

    engine = SyncEngine(
      outbox,
      OutboxSender(OperationsApi(dio)),
      effects,
      Talker(),
      _MockConnectivity(),
    );
    repo = CatalogRepository(CatalogApi(dio), cache, outbox, effects, engine);

    // Справочники «синхронизированы»: проход опирается на локальную базу.
    await cache.putGoods(const [good, otherGood]);
    await cache.putBarcodes([]);
  });

  tearDown(() => db.close());

  /// Привязки товара в локальном кэше.
  Future<List<Barcode>> cached(String goodId) => cache.barcodesOfGood(goodId);

  // ── Главный сценарий фазы ────────────────────────────────────────────────────────────────
  test(
    'офлайн-привязка переживает потерю связи и уходит при её возврате',
    () async {
      server.offline = true;

      // 1. Кладовщик привязывает ШК в мёртвой зоне.
      final res = await repo.bindBarcode(goodId: good.id, barcode: code);

      expect(
        res.isLeft,
        isTrue,
        reason: 'отправить не удалось — так и говорим',
      );
      expect(engine.link.value, LinkState.offline);
      final pending = await cached(good.id);
      expect(pending, hasLength(1), reason: 'кладовщик видит результат сразу');
      expect(
        pending.single.pending,
        isTrue,
        reason: 'но это ещё не факт справочника',
      );
      expect(await outbox.pendingCount(), 1, reason: 'операция ждёт в очереди');
      expect(server.applied, isEmpty, reason: 'до сервера ничего не дошло');

      // 2. Проход по очереди без связи ничего не теряет и не отправляет.
      final blocked = await engine.drain();
      expect(blocked.sent, 0);
      expect(blocked.remaining, 1);
      expect(await outbox.pendingCount(), 1);

      // 3. Связь вернулась.
      server.offline = false;
      final drained = await engine.drain();

      expect(drained.sent, 1);
      expect(drained.isDrained, isTrue);
      expect(engine.link.value, LinkState.online);
      expect(server.barcodes[code], good.id, reason: 'данные на сервере');

      final confirmed = await cached(good.id);
      expect(confirmed, hasLength(1), reason: 'привязка на месте');
      expect(
        confirmed.single.pending,
        isFalse,
        reason: 'сервер подтвердил — пометке больше нечего ждать',
      );
      expect(await outbox.pendingCount(), 0);
    },
  );

  // Ответ мог не дойти уже после того, как сервер операцию применил: процесс умер, статус
  // остался `sending`, и очередь шлёт её снова. Это штатный случай, а не сбой.
  test('переотправка после потерянного ответа не двоит данные', () async {
    await repo.bindBarcode(goodId: good.id, barcode: code);
    expect(server.applied, hasLength(1));

    // Возвращаем операцию в очередь, как будто ответ не дошёл.
    final sent = await db.select(db.outboxOperations).getSingle();
    await outbox.markFailed(sent.operationId, 'ответ не дошёл');
    expect(await outbox.pendingCount(), 1);

    final again = await engine.drain();

    expect(
      again.sent,
      1,
      reason: 'для очереди duplicate — успех: дело сделано',
    );
    expect(
      again.rejected,
      0,
      reason: 'успешная работа не должна попасть на разбор',
    );
    expect(server.applied, hasLength(1), reason: 'эффект применён один раз');
    expect(await cached(good.id), hasLength(1));
    expect((await cached(good.id)).single.pending, isFalse);
  });

  // Отказ по существу приходит внутри 200-го ответа. Он не лечится повтором, поэтому операция
  // выбывает из очереди, а локальное состояние возвращается к тому, что было.
  test('отклонённая сервером операция откатывается локально', () async {
    // ШК уже занят другим товаром на сервере.
    server.barcodes[code] = otherGood.id;

    final res = await repo.bindBarcode(goodId: good.id, barcode: code);

    expect(res.isLeft, isTrue);
    expect(res.left, isA<RejectedFailure>());
    expect(
      await cached(good.id),
      isEmpty,
      reason: 'иначе отклонённая привязка осталась бы в карточке навсегда',
    );
    expect(
      await outbox.pendingCount(),
      0,
      reason: 'повтор не поможет — из очереди выбыла',
    );
    final rejected = await outbox.watchRejected().first;
    expect(rejected, hasLength(1), reason: 'видна на экране разбора');
    expect(
      rejected.single.lastError,
      contains('another good'),
      reason: 'с причиной от сервера дословно',
    );
    expect(
      engine.link.value,
      LinkState.online,
      reason: 'сервер ответил — это не потеря связи',
    );
  });

  // Порядок операций решает исход: «привязать» и «отвязать» один ШК задом наперёд дают
  // противоположный результат. Накопленная за смену очередь уходит одним запросом.
  test(
    'накопленная очередь уходит одним запросом и в порядке постановки',
    () async {
      server.offline = true;
      await repo.bindBarcode(goodId: good.id, barcode: code);
      await repo.unbindBarcode(goodId: good.id, barcode: code);
      await repo.bindBarcode(goodId: otherGood.id, barcode: code);
      expect(await outbox.pendingCount(), 3);

      server.offline = false;
      server.requests = 0;
      final drained = await engine.drain();

      expect(drained.sent, 3);
      expect(server.requests, 1, reason: 'три операции — один запрос');
      expect(
        server.barcodes[code],
        otherGood.id,
        reason: 'порядок соблюдён: привязали, отвязали, привязали заново',
      );
      expect(await outbox.pendingCount(), 0);
    },
  );

  // Очередь переживает перезапуск приложения: она на диске, а не в памяти движка.
  test('очередь переживает перезапуск и уходит под следующим входом', () async {
    server.offline = true;
    await repo.bindBarcode(goodId: good.id, barcode: code);

    // Новый движок на той же базе — как после перезапуска процесса.
    final restarted = SyncEngine(
      OutboxRepository(db, const Uuid()),
      OutboxSender(
        OperationsApi(
          Dio(BaseOptions(baseUrl: 'https://api.test/api/v1/'))
            ..httpClientAdapter = server,
        ),
      ),
      OutboxEffects(
        cache,
        FakeContentsSnapshotSync(),
        FakeTasksSnapshotSync(),
      ),
      Talker(),
      _MockConnectivity(),
    );
    server.offline = false;

    final drained = await restarted.drain();

    expect(drained.sent, 1, reason: 'операция пережила перезапуск');
    expect(server.barcodes[code], good.id);
  });
}
