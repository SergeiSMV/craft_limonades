import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/outbox/outbox_retry.dart';
import 'package:craft_wms/core/outbox/outbox_sender.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

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

  setUpAll(() => registerFallbackValue(_FakeOperation()));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
    sender = _MockSender();
    engine = SyncEngine(outbox, sender, Talker(), _MockConnectivity());
  });

  tearDown(() => db.close());

  /// Поставить в очередь привязку ШК.
  Future<String> enqueue(String barcode) => outbox.enqueue(
    kind: OutboxKind.bindBarcode,
    payload: {'good_id': 'g1', 'barcode': barcode},
  );

  test('пустая очередь — проход ничего не делает', () async {
    final res = await engine.drain();

    expect(res.sent, 0);
    expect(res.isDrained, isTrue);
    verifyNever(() => sender.send(any()));
  });

  test('очередь уходит целиком в порядке постановки', () async {
    final order = <String>[];
    for (final code in ['a', 'b', 'c']) {
      await enqueue(code);
    }
    when(() => sender.send(any())).thenAnswer((invocation) async {
      final op = invocation.positionalArguments.first as OutboxOperation;
      order.add(op.payload['barcode'] as String);
      return const Right(null);
    });

    final res = await engine.drain();

    expect(order, ['a', 'b', 'c']);
    expect(res.sent, 3);
    expect(res.isDrained, isTrue);
    expect(await outbox.pendingCount(), 0);
  });

  // Порядок важнее скорости: «привязать ШК» и «отвязать ШК» дают разный итог в разной
  // последовательности, и перескочить через застрявшую операцию значит применить их наоборот.
  test('временная неудача останавливает проход, очередь сохраняется', () async {
    await enqueue('a');
    await enqueue('b');
    when(
      () => sender.send(any()),
    ).thenAnswer((_) async => const Left(Failure.network()));

    final res = await engine.drain();

    expect(res.sent, 0);
    expect(res.remaining, 2, reason: 'вторая операция даже не пробовалась');
    verify(() => sender.send(any())).called(1);
    final pending = await outbox.pending();
    expect(pending.first.attempts, 1);
    expect(pending.last.attempts, 0);
  });

  // Отказ по существу порядку не мешает: такая операция выбывает совсем.
  test('отказ по существу выводит операцию, проход продолжается', () async {
    await enqueue('a');
    await enqueue('b');
    when(() => sender.send(any())).thenAnswer((invocation) async {
      final op = invocation.positionalArguments.first as OutboxOperation;
      return op.payload['barcode'] == 'a'
          ? const Left(Failure.server(409))
          : const Right(null);
    });

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
      when(
        () => sender.send(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      await engine.drain();
      expect(await outbox.pendingCount(), 1);

      when(() => sender.send(any())).thenAnswer((_) async => const Right(null));
      final res = await engine.drain();

      expect(res.sent, 1);
      expect(await outbox.pendingCount(), 0);
    },
  );

  test('отправленные убираются после полной разгрузки', () async {
    await enqueue('a');
    when(() => sender.send(any())).thenAnswer((_) async => const Right(null));

    await engine.drain();

    final all = await db.select(db.outboxOperations).get();
    expect(all, isEmpty, reason: 'очередь — список дел, а не журнал');
  });

  // Разбудить движок могут одновременно вход, возврат на передний план и событие сети;
  // две параллельные отправки одной операции — это два запроса вместо одного.
  test('повторный вход в проход не удваивает отправку', () async {
    await enqueue('a');
    when(() => sender.send(any())).thenAnswer((_) async {
      // Пока первый проход ждёт сеть, зовём второй — он должен уйти ни с чем.
      final concurrent = await engine.drain();
      expect(concurrent.sent, 0);
      return const Right(null);
    });

    final res = await engine.drain();

    expect(res.sent, 1);
    verify(() => sender.send(any())).called(1);
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
