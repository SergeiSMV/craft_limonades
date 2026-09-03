import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/sync/presentation/pages/sync_queue_page.dart';
import 'package:craft_wms/features/sync/presentation/widgets/operation_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockOutbox extends Mock implements OutboxRepository {}

class _MockCache extends Mock implements CatalogCache {}

/// Экран несинхронизированных операций (P2-06): проводка списков и разбор.
///
/// Репозиторий подменён намеренно. С настоящей базой экран тянул бы drift-подписки, а drift
/// на отмену подписки заводит таймер нулевой длительности — дерево разбирается уже после тела
/// теста, и проверка «не осталось висящих таймеров» роняет тест. Подменённый репозиторий отдаёт
/// обычные `Stream.value`, отменять там нечего, и проверяется ровно то, ради чего экран есть:
/// какой список откуда берётся и что делают кнопки разбора.
void main() {
  late _MockOutbox outbox;

  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');

  /// Операция очереди для показа.
  OutboxOperation operation({
    required int seq,
    OutboxKind kind = OutboxKind.bindBarcode,
    OutboxStatus status = OutboxStatus.rejected,
    String? error,
  }) => OutboxOperation(
    seq: seq,
    operationId: 'op-$seq',
    kind: kind,
    payload: {'good_id': good.id, 'barcode': '4851388$seq'},
    status: status,
    attempts: 0,
    lastError: error,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  setUp(() {
    LocaleSettings.useDeviceLocale();
    outbox = _MockOutbox();
    when(() => outbox.watchRejected()).thenAnswer((_) => Stream.value(const []));
    when(() => outbox.watchPending()).thenAnswer((_) => Stream.value(const []));
    when(() => outbox.retry(any())).thenAnswer((_) async {});
    when(() => outbox.discard(any())).thenAnswer((_) async {});

    final cache = _MockCache();
    when(() => cache.goodById(any())).thenAnswer((_) async => good);

    if (getIt.isRegistered<OutboxRepository>()) {
      getIt.unregister<OutboxRepository>();
    }
    if (getIt.isRegistered<CatalogCache>()) getIt.unregister<CatalogCache>();
    getIt.registerSingleton<OutboxRepository>(outbox);
    getIt.registerSingleton<CatalogCache>(cache);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SyncQueuePage()));
    await tester.pump();
  }

  testWidgets('пустая очередь — экран так и говорит', (tester) async {
    await pump(tester);

    expect(find.text(t.syncQueue.empty), findsOneWidget);
  });

  // Проводка: отклонённые и ожидающие приходят из РАЗНЫХ потоков и попадают в свои разделы.
  // Перепутай их местами — ни один другой тест этого не заметит.
  testWidgets('отклонённые и ожидающие разложены по своим разделам', (
    tester,
  ) async {
    when(() => outbox.watchRejected()).thenAnswer(
      (_) =>
          Stream.value([operation(seq: 1, error: 'ШК уже за другим товаром')]),
    );
    when(() => outbox.watchPending()).thenAnswer(
      (_) => Stream.value([operation(seq: 2, status: OutboxStatus.pending)]),
    );

    await pump(tester);

    expect(find.text(t.syncQueue.rejectedTitle(count: 1)), findsOneWidget);
    expect(find.text(t.syncQueue.pendingTitle(count: 1)), findsOneWidget);
    expect(find.text(t.syncQueue.opBind(barcode: '48513881')), findsOneWidget);
    expect(find.text(t.syncQueue.opBind(barcode: '48513882')), findsOneWidget);
    // Кнопки разбора — только у отклонённой; ожидающая уйдёт сама.
    expect(find.text(t.syncQueue.retry), findsOneWidget);
    expect(find.text(t.syncQueue.discard), findsOneWidget);
  });

  testWidgets('«Повторить» возвращает в очередь именно эту операцию', (
    tester,
  ) async {
    when(() => outbox.watchRejected()).thenAnswer(
      (_) => Stream.value([operation(seq: 1, error: 'сервер отказал (500)')]),
    );
    await pump(tester);

    await tester.tap(find.text(t.syncQueue.retry));
    await tester.pump();

    verify(() => outbox.retry('op-1')).called(1);
    verifyNever(() => outbox.discard(any()));
  });

  // Отброс необратим: восстановить операцию можно только повторив саму работу — снова найти
  // товар и отсканировать код. Поэтому подтверждение обязательно.
  testWidgets('«Отбросить» удаляет только после подтверждения', (tester) async {
    when(() => outbox.watchRejected()).thenAnswer(
      (_) => Stream.value([operation(seq: 1, error: 'сервер отказал (409)')]),
    );
    await pump(tester);

    // Кнопка в списке и подтверждение в диалоге подписаны одинаково, поэтому ищем по месту:
    // иначе тап не знает, во что целиться.
    final inList = find.descendant(
      of: find.byType(OperationTile),
      matching: find.text(t.syncQueue.discard),
    );
    final inDialog = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(t.syncQueue.discardConfirm),
    );

    await tester.tap(inList);
    await tester.pump();
    expect(find.text(t.syncQueue.discardTitle), findsOneWidget);

    await tester.tap(find.text(t.syncQueue.cancel));
    await tester.pump();
    verifyNever(() => outbox.discard(any()));

    await tester.tap(inList);
    await tester.pump();
    await tester.tap(inDialog);
    await tester.pump();

    verify(() => outbox.discard('op-1')).called(1);
    verifyNever(() => outbox.retry(any()));
  });
}
