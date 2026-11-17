import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/receipt/data/receipt_repository_impl.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
// Только Migrator: полный экспорт drift переопределяет матчеры теста.
import 'package:drift/drift.dart' show Migrator;
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockSync extends Mock implements SyncEngine {}

class _FakeOperation extends Fake implements OutboxOperation {}

/// Приёмка уходит в очередь операций (P4-09) и переживает отсутствие связи.
void main() {
  late AppDatabase db;
  late OutboxRepository outbox;
  late _MockSync sync;

  setUpAll(() => registerFallbackValue(_FakeOperation()));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
    sync = _MockSync();
  });

  tearDown(() => db.close());

  test(
    'без связи приёмка остаётся в очереди одной операцией receipt_submit',
    () async {
      when(
        () => sync.sendOne(any()),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final repo = ReceiptRepositoryImpl(outbox, sync);
      final payload = {
        'receipt_id': 'r1',
        'warehouse_id': 'w1',
        'lines': [
          {'good_id': 'g1', 'production_date': '01-09-2026', 'qty': 1},
        ],
      };

      final res = await repo.submit(payload);

      expect(res.isLeft, isTrue);
      final pending = await outbox.pending();
      expect(pending.single.kind, OutboxKind.receiptSubmit);
      expect(
        pending.single.kind.wire,
        'receipt_submit',
      ); // строка совпадает с сервером
      expect(pending.single.payload['receipt_id'], 'r1');

      // Повторное «Завершить» той же приёмки (например, после перезапуска посреди отправки)
      // не ставит вторую операцию: иначе на сервере вторая упёрлась бы в «уже оприходована».
      await repo.submit(payload);
      expect(await outbox.pendingCount(), 1);
    },
  );

  // Колонка дефолтной ячейки встаёт со значением «нет», то есть кэш тут же врал бы. Миграция
  // снимает отметку о загрузке ячеек - до следующей синхронизации их читают с сервера.
  test(
    'миграция 4 → 5 добавляет флаг и сбрасывает готовность кэша ячеек',
    () async {
      final cache = CatalogCache(db);
      await cache.putCells(const []);
      expect(await cache.has(CatalogName.cells), isTrue);
      await db.customStatement(
        'ALTER TABLE cached_cells DROP COLUMN is_default',
      );

      await db.migration.onUpgrade(Migrator(db), 4, 5);

      expect(await cache.has(CatalogName.cells), isFalse);
      expect(
        await cache.cells(),
        isEmpty,
      ); // колонка на месте - чтение не падает
    },
  );
}
