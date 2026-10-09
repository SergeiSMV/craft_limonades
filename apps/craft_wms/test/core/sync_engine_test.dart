import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_effects.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_retry.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/link_state.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';
import '../support/contents_stubs.dart';

class _MockSender extends Mock implements OutboxSender {}

class _MockConnectivity extends Mock implements Connectivity {}

class _FakeOperation extends Fake implements OutboxOperation {}

/// Движок синхронизации (P2-04): разгребает очередь, повторяет временные отказы и выводит
/// из очереди отказы по существу.
void main() {
  late AppDatabase db;
  late OutboxRepository outbox;
  late _MockSender sender;
  late SyncEngine engine;

  setUpAll(() {
    registerFallbackValue(_FakeOperation());
    registerFallbackValue(<OutboxOperation>[]);
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
    sender = _MockSender();
    engine = SyncEngine(
      outbox,
      sender,
      OutboxEffects(
        CatalogCache(db),
        FakeContentsSnapshotSync(),
        FakeTasksSnapshotSync(),
      ),
      Talker(),
      _MockConnectivity(),
    );
  });

  tearDown(() => db.close());

  /// Заглушка пачки: сервер разбирает операции ПО ПОРЯДКУ и прекращает на первой временной
  /// неудаче — ровно так, как это делает настоящий бэкенд (P2-05). Операции после остановки
  /// исхода не получают, и очередь обязана оставить их себе.
  void stubBatch(Either<Failure, void> Function(OutboxOperation) decide) {
    when(() => sender.sendBatch(any())).thenAnswer((invocation) async {
      final ops = invocation.positionalArguments.first as List<OutboxOperation>;
      final outcomes = <String, Either<Failure, void>>{};
      for (final op in ops) {
        final res = decide(op);
        if (res.isLeft && isRetryable(res.left)) break;
        outcomes[op.operationId] = res;
      }
      return Right(outcomes);
    });
  }

  /// Пачка не доехала целиком (сеть, 5xx).
  void stubBatchDown(Failure failure) {
    when(() => sender.sendBatch(any())).thenAnswer((_) async => Left(failure));
  }

  /// Поставить в очередь привязку ШК.
  Future<String> enqueue(String barcode) => outbox.enqueue(
    kind: OutboxKind.bindBarcode,
    payload: {'good_id': 'g1', 'barcode': barcode},
  );

  test('пустая очередь — проход ничего не делает', () async {
    final res = await engine.drain();

    expect(res.sent, 0);
    expect(res.isDrained, isTrue);
    verifyNever(() => sender.sendBatch(any()));
  });

  test('очередь уходит целиком в порядке постановки', () async {
    final order = <String>[];
    for (final code in ['a', 'b', 'c']) {
      await enqueue(code);
    }
    stubBatch((op) {
      order.add(op.payload['barcode'] as String);
      return const Right(null);
    });

    final res = await engine.drain();

    expect(order, ['a', 'b', 'c']);
    expect(res.sent, 3);
    expect(res.isDrained, isTrue);
    expect(await outbox.pendingCount(), 0);
  });

  // Ради этого батч и заводился: на складе связь короткая, и три отдельных запроса вместо
  // одного — это три шанса оборваться вместо одного.
  test('очередь уходит ОДНИМ запросом, а не по запросу на операцию', () async {
    for (final code in ['a', 'b', 'c']) {
      await enqueue(code);
    }
    var requests = 0;
    var largestChunk = 0;
    when(() => sender.sendBatch(any())).thenAnswer((invocation) async {
      requests++;
      final ops = invocation.positionalArguments.first as List<OutboxOperation>;
      largestChunk = ops.length;
      return Right({
        for (final op in ops) op.operationId: const Right<Failure, void>(null),
      });
    });

    final res = await engine.drain();

    expect(res.sent, 3);
    expect(requests, 1, reason: 'три операции — один запрос');
    expect(largestChunk, 3);
  });

  // Порядок важнее скорости: «привязать ШК» и «отвязать ШК» дают разный итог в разной
  // последовательности, и перескочить через застрявшую операцию значит применить их наоборот.
  test('временная неудача останавливает проход, очередь сохраняется', () async {
    await enqueue('a');
    await enqueue('b');
    stubBatch((_) => const Left(Failure.network()));

    final res = await engine.drain();

    expect(res.sent, 0);
    expect(res.remaining, 2, reason: 'вторая операция даже не пробовалась');
    verify(() => sender.sendBatch(any())).called(1);
    final pending = await outbox.pending();
    expect(pending.first.attempts, 1);
    expect(
      pending.last.attempts,
      0,
      reason: 'до неё сервер не дошёл — попытки ей не засчитываем',
    );
  });

  // Отказ по существу порядку не мешает: такая операция выбывает совсем.
  test('отказ по существу выводит операцию, проход продолжается', () async {
    await enqueue('a');
    await enqueue('b');
    stubBatch(
      (op) => op.payload['barcode'] == 'a'
          ? const Left(Failure.server(409))
          : const Right(null),
    );

    final res = await engine.drain();

    expect(res.rejected, 1);
    expect(res.sent, 1);
    expect(res.isDrained, isTrue);
  });

  // Главный сценарий задачи: связи не было, операция осталась; связь появилась — ушла сама.
  test(
    'операция уходит со следующего прохода, когда связь вернулась',
    () async {
      await enqueue('a');
      stubBatchDown(const Failure.network());
      await engine.drain();
      expect(await outbox.pendingCount(), 1);

      stubBatch((_) => const Right(null));
      final res = await engine.drain();

      expect(res.sent, 1);
      expect(await outbox.pendingCount(), 0);
    },
  );

  test('отправленные убираются после полной разгрузки', () async {
    await enqueue('a');
    stubBatch((_) => const Right(null));

    await engine.drain();

    final all = await db.select(db.outboxOperations).get();
    expect(all, isEmpty, reason: 'очередь — список дел, а не журнал');
  });

  // Разбудить движок могут одновременно вход, возврат на передний план и событие сети;
  // две параллельные отправки одной операции — это два запроса вместо одного.
  test('повторный вход в проход не удваивает отправку', () async {
    await enqueue('a');
    when(() => sender.sendBatch(any())).thenAnswer((invocation) async {
      // Пока первый проход ждёт сеть, зовём второй — он должен уйти ни с чем.
      final concurrent = await engine.drain();
      expect(concurrent.sent, 0);
      final ops = invocation.positionalArguments.first as List<OutboxOperation>;
      return Right({
        for (final op in ops) op.operationId: const Right<Failure, void>(null),
      });
    });

    final res = await engine.drain();

    expect(res.sent, 1);
    verify(() => sender.sendBatch(any())).called(1);
  });

  // Статус связи (P2-07). Главное требование — он не должен врать: «Wi-Fi подключён» и
  // «сервер отвечает» на складе расходятся регулярно, и индикатор по одной связности
  // показывал бы «онлайн» ровно там, где отправить ничего нельзя.
  group('статус связи', () {
    test('до первого обмена — «неизвестно», а не «офлайн»', () {
      expect(
        engine.link.value,
        LinkState.unknown,
        reason:
            'сказать «нет связи» там, где мы не пробовали, — соврать в другую сторону',
      );
    });

    test('удавшийся обмен — онлайн', () async {
      await enqueue('a');
      stubBatch((_) => const Right(null));

      await engine.drain();

      expect(engine.link.value, LinkState.online);
    });

    test('пачка не доехала — офлайн', () async {
      await enqueue('a');
      stubBatchDown(const Failure.network());

      await engine.drain();

      expect(engine.link.value, LinkState.offline);
    });

    // Сервер, отказавший по существу, — это работающий сервер. Считать такой ответ потерей
    // связи значит показать «нет связи» человеку, которому сервер только что ответил.
    test('отказ по существу — онлайн, а не потеря связи', () async {
      await enqueue('a');
      stubBatch((_) => const Left(Failure.server(409)));

      await engine.drain();

      expect(engine.link.value, LinkState.online);
    });

    // Немедленная отправка из репозитория идёт мимо разбора пачки, своим путём (sendOne),
    // и учёт связи там отдельный. Без этого теста ветка «сервер ответил отказом по существу»
    // не проверялась вовсе: проход по очереди до неё не доходит.
    test('немедленная отправка: отказ по существу — онлайн', () async {
      await enqueue('a');
      final operation = (await outbox.pending()).single;
      when(
        () => sender.send(any()),
      ).thenAnswer((_) async => const Left(Failure.server(409)));

      await engine.sendOne(operation);

      expect(
        engine.link.value,
        LinkState.online,
        reason: 'сервер ответил — считать это потерей связи значит соврать',
      );
    });

    test('немедленная отправка: обрыв — офлайн', () async {
      await enqueue('a');
      final operation = (await outbox.pending()).single;
      when(
        () => sender.send(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));

      await engine.sendOne(operation);

      expect(engine.link.value, LinkState.offline);
    });

    test(
      'признак отправки поднимается на время прохода и гаснет после',
      () async {
        await enqueue('a');
        final seen = <bool>[];
        when(() => sender.sendBatch(any())).thenAnswer((invocation) async {
          seen.add(engine.syncing.value);
          final ops =
              invocation.positionalArguments.first as List<OutboxOperation>;
          return Right({
            for (final op in ops)
              op.operationId: const Right<Failure, void>(null),
          });
        });

        await engine.drain();

        expect(seen, [true], reason: 'во время обмена экран обязан это видеть');
        expect(engine.syncing.value, isFalse);
      },
    );
  });

  group('пауза перед повтором', () {
    test('растёт с числом попыток и упирается в потолок', () {
      expect(retryDelay(0), const Duration(seconds: 5));
      expect(retryDelay(1), const Duration(seconds: 15));
      expect(retryDelay(4), const Duration(minutes: 5));
      expect(
        retryDelay(99),
        const Duration(minutes: 5),
        reason: 'дольше ждать незачем — событие сети разбудит раньше',
      );
    });

    test('повторяем только то, что не зависит от содержания запроса', () {
      expect(isRetryable(const Failure.network()), isTrue);
      expect(isRetryable(const Failure.server(503)), isTrue);
      expect(isRetryable(const Failure.auth()), isTrue);
      expect(isRetryable(const Failure.server(409)), isFalse);
      expect(isRetryable(const Failure.server(400)), isFalse);
    });
  });
}
