import 'dart:io';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста (isNotNull и др.).
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

/// Очередь исходящих операций (P2-03): постановка, порядок, статусы и — главное —
/// переживание перезапуска приложения.
void main() {
  late AppDatabase db;
  late OutboxRepository outbox;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
  });

  tearDown(() => db.close());

  group('постановка в очередь', () {
    test('операция ложится со статусом pending и своим operation_id', () async {
      final id = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: {'good_id': 'g1', 'barcode': '4607044662964'},
      );

      final op = await outbox.byOperationId(id);
      expect(op, isNotNull);
      expect(op!.kind, OutboxKind.bindBarcode);
      expect(op.status, OutboxStatus.pending);
      expect(op.attempts, 0);
      expect(op.payload['barcode'], '4607044662964');
    });

    test('operation_id уникален у каждой операции', () async {
      final first = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );
      final second = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'b'},
      );

      expect(first, isNot(second));
    });

    // Порядок решает исход: «привязать ШК» и следом «отвязать ШК» дают не тот же результат,
    // что обратная пара. Поэтому очередь строго FIFO, а не «набор ожидающих».
    test('порядок выдачи — порядок постановки', () async {
      for (final code in ['a', 'b', 'c']) {
        await outbox.enqueue(
          kind: OutboxKind.bindBarcode,
          payload: {'barcode': code},
        );
      }

      final pending = await outbox.pending();

      expect(pending.map((o) => o.payload['barcode']).toList(), [
        'a',
        'b',
        'c',
      ]);
    });
  });

  group('статусы', () {
    test('markSent убирает операцию из ожидающих', () async {
      final id = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );

      await outbox.markSent(id);

      expect(await outbox.pending(), isEmpty);
      expect((await outbox.byOperationId(id))!.status, OutboxStatus.sent);
    });

    test('markFailed возвращает в очередь и считает попытки', () async {
      final id = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );

      await outbox.markSending(id);
      await outbox.markFailed(id, 'нет связи');
      await outbox.markSending(id);
      await outbox.markFailed(id, 'нет связи');

      final op = await outbox.byOperationId(id);
      expect(op!.status, OutboxStatus.pending);
      expect(op.attempts, 2);
      expect(op.lastError, 'нет связи');
      expect(await outbox.pending(), hasLength(1));
    });

    test('markRejected выводит операцию из очереди навсегда', () async {
      final id = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );

      await outbox.markRejected(id, 'ШК уже за другим товаром');

      expect(await outbox.pending(), isEmpty);
      expect((await outbox.byOperationId(id))!.status, OutboxStatus.rejected);
    });

    // Процесс умер во время отправки: дошёл запрос или нет — неизвестно. Оставить такую
    // операцию вне очереди значит потерять её, если она не дошла; повтор безопасен, потому
    // что дедуп по operation_id отбросит её, если дошла (P2-05).
    test('застрявшие в отправке возвращаются в очередь', () async {
      final id = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );
      await outbox.markSending(id);

      final pending = await outbox.pending();

      expect(pending, hasLength(1));
      expect(pending.single.status, OutboxStatus.sending);
      expect(await outbox.pendingCount(), 1);
    });

    test('purgeSent чистит только отправленные', () async {
      final sent = await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'a'},
      );
      await outbox.enqueue(
        kind: OutboxKind.bindBarcode,
        payload: const {'barcode': 'b'},
      );
      await outbox.markSent(sent);

      expect(await outbox.purgeSent(), 1);
      expect(await outbox.pendingCount(), 1);
    });
  });

  // Строку мог записать более новый билд приложения, а пользователь откатился на старый.
  // Отправлять операцию, тип которой не разбирается, вслепую нельзя.
  test('операция незнакомого типа пропускается, но остаётся в базе', () async {
    await db
        .into(db.outboxOperations)
        .insert(
          OutboxOperationsCompanion.insert(
            operationId: 'op-future',
            kind: 'move_cargo_unit', // такого типа в этой версии ещё нет
            payload: '{}',
            status: OutboxStatus.pending.wire,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

    expect(await outbox.pending(), isEmpty);
    expect(
      await outbox.pendingCount(),
      1,
      reason: 'строка на месте, не удалена',
    );
  });

  // Критерий готовности P2-03 целиком: «операции пишутся в очередь и не теряются при
  // рестарте». База в памяти этого не покажет — нужен файл, закрытие и открытие заново.
  test('операции переживают перезапуск приложения', () async {
    final dir = await Directory.systemTemp.createTemp('craft_wms_outbox');
    final file = File('${dir.path}/craft_wms.sqlite');
    addTearDown(() => dir.delete(recursive: true));

    final first = AppDatabase.forTesting(NativeDatabase(file));
    final firstOutbox = OutboxRepository(first, const Uuid());
    final id = await firstOutbox.enqueue(
      kind: OutboxKind.unbindBarcode,
      payload: const {'barcode': '4607044662964'},
    );
    await firstOutbox.markSending(id); // отправка началась и не завершилась
    await first.close(); // «приложение убито»

    final second = AppDatabase.forTesting(NativeDatabase(file));
    final secondOutbox = OutboxRepository(second, const Uuid());
    addTearDown(() => second.close());

    final pending = await secondOutbox.pending();
    expect(pending, hasLength(1));
    expect(pending.single.operationId, id);
    expect(pending.single.kind, OutboxKind.unbindBarcode);
    expect(pending.single.payload['barcode'], '4607044662964');
  });

  // Схема жила в версии 1 и стратегии миграции не имела вовсе, а на терминалах эта база
  // уже лежит с наполненными справочниками. Проверяем именно путь обновления: новых таблиц
  // нет, кэш есть — после миграции таблицы появились, кэш цел.
  test('миграция 1 → 2 добавляет таблицы и не трогает кэш', () async {
    await db
        .into(db.cachedSuppliers)
        .insert(CachedSuppliersCompanion.insert(id: 's1', name: 'Поставщик'));
    // Возвращаем базу к состоянию схемы 1.
    await db.customStatement('DROP TABLE outbox_operations');
    await db.customStatement('DROP TABLE entry_drafts');

    await db.migration.onUpgrade(Migrator(db), 1, 2);

    await outbox.enqueue(
      kind: OutboxKind.bindBarcode,
      payload: const {'barcode': 'a'},
    );
    expect(await outbox.pendingCount(), 1);
    expect(await db.select(db.cachedSuppliers).get(), hasLength(1));
  });
}
