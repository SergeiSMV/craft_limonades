import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/sync/presentation/widgets/operation_tile.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Строка операции в списке несинхронизированного (P2-06).
///
/// Проверяется именно плитка, а не экран целиком: экран — тонкая склейка двух живых списков
/// из очереди, и его поведение уже закрыто тестами репозитория (списки, повтор, отброс).
/// Виджет-тест самого экрана дрался бы с таймером, который drift заводит при отмене подписки
/// на запрос, и стоил бы десяти минут на прогон, ничего не проверяя сверх этого.
void main() {
  late AppDatabase db;

  const good = Good(id: 'g1', name: 'Арахис жареный', uom: 'шт');

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final cache = CatalogCache(db);
    await cache.putGoods(const [good]);
    if (getIt.isRegistered<CatalogCache>()) getIt.unregister<CatalogCache>();
    getIt.registerSingleton<CatalogCache>(cache);
  });

  tearDown(() => db.close());

  /// Операция очереди для показа.
  OutboxOperation operation({
    OutboxKind kind = OutboxKind.bindBarcode,
    OutboxStatus status = OutboxStatus.rejected,
    String? error,
    int attempts = 0,
  }) => OutboxOperation(
    seq: 1,
    operationId: 'op-1',
    kind: kind,
    payload: {'good_id': good.id, 'barcode': '48513883'},
    status: status,
    attempts: attempts,
    lastError: error,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  Future<void> pump(WidgetTester tester, Widget tile) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tile)));
    await tester.pump(); // название товара подтягивается из базы отдельным кадром
  }

  testWidgets('операция описана по-человечески, с товаром и причиной', (
    tester,
  ) async {
    await pump(
      tester,
      OperationTile(
        operation: operation(error: 'ШК уже за другим товаром'),
        onRetry: () {},
        onDiscard: () {},
      ),
    );

    expect(find.text(t.syncQueue.opBind(barcode: '48513883')), findsOneWidget);
    expect(
      find.text(good.name),
      findsOneWidget,
      reason: 'без названия товара решать «повторить или отбросить» не по чему',
    );
    expect(
      find.text(t.syncQueue.reason(reason: 'ШК уже за другим товаром')),
      findsOneWidget,
    );
  });

  testWidgets('отвязка описана своим текстом', (tester) async {
    await pump(
      tester,
      OperationTile(operation: operation(kind: OutboxKind.unbindBarcode)),
    );

    expect(find.text(t.syncQueue.opUnbind(barcode: '48513883')), findsOneWidget);
  });

  // Ожидающая операция уйдёт сама — разбирать её нечего, и кнопок у неё быть не должно.
  testWidgets('без разбора кнопок нет', (tester) async {
    await pump(
      tester,
      OperationTile(operation: operation(status: OutboxStatus.pending)),
    );

    expect(find.text(t.syncQueue.retry), findsNothing);
    expect(find.text(t.syncQueue.discard), findsNothing);
  });

  testWidgets('у отклонённой есть повтор и отброс', (tester) async {
    var retried = false;
    var discarded = false;
    await pump(
      tester,
      OperationTile(
        operation: operation(error: 'сервер отказал (409)'),
        onRetry: () => retried = true,
        onDiscard: () => discarded = true,
      ),
    );

    await tester.tap(find.text(t.syncQueue.retry));
    await tester.tap(find.text(t.syncQueue.discard));

    expect(retried, isTrue);
    expect(discarded, isTrue);
  });

  testWidgets('число попыток показывается, когда они были', (tester) async {
    await pump(tester, OperationTile(operation: operation(attempts: 3)));

    expect(find.text(t.syncQueue.attempts(count: 3)), findsOneWidget);
  });
}
