import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/picking/data/picking_api.dart';
import 'package:craft_wms/features/picking/data/picking_repository_impl.dart';
import 'package:craft_wms/features/picking/data/picking_store.dart';
import 'package:craft_wms/features/picking/domain/picking_models.dart';
import 'package:craft_wms/features/picking/domain/picking_repository.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/uuid.dart';

class _MockApi extends Mock implements PickingApi {}

class _MockSync extends Mock implements SyncEngine {}

class _FakeOperation extends Fake implements OutboxOperation {}

const _orderId = '11111111-1111-4111-8111-111111111111';
const _lineId = '22222222-2222-4222-8222-222222222222';
const _boxId = '33333333-3333-4333-8333-333333333333';
const _cellId = '44444444-4444-4444-8444-444444444444';

PickingOrder _order({double taken = 0, List<PickingPick> picks = const []}) =>
    PickingOrder(
      id: _orderId,
      number: 7,
      registryDate: '2026-11-09',
      status: PickingStatus.inProgress,
      mine: true,
      lines: [
        PickingLine(
          id: _lineId,
          goodId: 'g1',
          goodName: 'Лимонад',
          uom: 'шт',
          planQty: 8,
          taken: taken,
        ),
      ],
      boxes: const [PickingBox(loadUnitId: _boxId, seq: 1)],
      picks: picks,
    );

const _request = PickRequest(
  orderId: _orderId,
  lineId: _lineId,
  sourceCellId: _cellId,
  cellAddress: 'A-1',
  productionDate: '01-10-2026',
  qty: 5,
);

/// Сборка на терминале (P9-06): слепок заказа, пик и возврат очередью, «взято» с очередью.
void main() {
  late AppDatabase db;
  late OutboxRepository outbox;
  late _MockApi api;
  late _MockSync sync;
  late PickingRepository repo;

  setUpAll(() => registerFallbackValue(_FakeOperation()));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = OutboxRepository(db, const Uuid());
    api = _MockApi();
    sync = _MockSync();
    repo = PickingRepositoryImpl(
      api,
      PickingStore(db),
      outbox,
      sync,
      const Uuid(),
      const LoadUnitIdGenerator(Uuid()),
    );
    when(
      () => sync.sendOne(any()),
    ).thenAnswer((_) async => const Left(Failure.network()));
  });

  tearDown(() => db.close());

  void serverReturns(PickingOrder order) =>
      when(() => api.order(_orderId)).thenAnswer((_) async => Right(order));

  test('без связи заказ открывается из слепка терминала', () async {
    serverReturns(_order());
    expect((await repo.order(_orderId)).right.fromCache, isFalse);

    when(
      () => api.order(_orderId),
    ).thenAnswer((_) async => const Left(Failure.network()));
    final res = await repo.order(_orderId);

    expect(res.right.fromCache, isTrue);
    expect(res.right.currentBoxId, _boxId);
  });

  test('отказ сервера по существу слепком не подменяется', () async {
    serverReturns(_order());
    await repo.order(_orderId);
    when(() => api.order(_orderId)).thenAnswer(
      (_) async => const Left(Failure.server(409, 'заказ удалён в 1С')),
    );

    expect((await repo.order(_orderId)).isLeft, isTrue);
  });

  test(
    'пик без связи - операция picking_pick в очереди, «взято» с ней',
    () async {
      serverReturns(_order());
      await repo.order(_orderId);

      final res = await repo.pick(_request);

      expect(res.left, isA<NetworkFailure>());
      final op = (await outbox.pending()).single;
      expect(op.kind.wire, 'picking_pick');
      expect(op.payload['order_id'], _orderId);
      expect(op.payload['line_id'], _lineId);
      expect(op.payload['box_id'], _boxId);
      expect(op.payload['source_cell_id'], _cellId);
      expect(op.payload['source_load_unit_id'], '');
      expect(op.payload['production_date'], '01-10-2026');
      expect(op.payload['qty'], '5.0');
      expect(op.payload['pick_id'], isNotEmpty);

      final view = (await repo.cached(_orderId))!;
      final line = view.order.lines.single;
      expect(view.taken(line), 5);
      expect(view.remaining(line), 3);
      expect(view.picksOf(_lineId).single.pending, isTrue);

      // Свежий ответ сервера о пике ещё не знает - пик из очереди остаётся поверх.
      final again = (await repo.order(_orderId)).right;
      expect(again.taken(again.order.lines.single), 5);
    },
  );

  test(
    'завершить сборку с неотправленным пиком - сначала очередь, без связи отказ',
    () async {
      serverReturns(_order());
      await repo.order(_orderId);
      await repo.pick(_request);
      when(() => sync.drain()).thenAnswer(
        (_) async => const SyncResult(sent: 0, rejected: 0, remaining: 1),
      );

      final res = await repo.complete(_orderId);

      expect(res.left, isA<NetworkFailure>());
      verify(() => sync.drain()).called(1);
      verifyNever(() => api.complete(any()));
    },
  );

  test('подтверждённый пик в ответе сервера не задваивается', () async {
    serverReturns(_order());
    await repo.order(_orderId);
    when(() => sync.sendOne(any())).thenAnswer((inv) async {
      final op = inv.positionalArguments.first as OutboxOperation;
      await outbox.markSent(op.operationId);
      return const Right(null);
    });

    await repo.pick(_request);
    final pickId = (await repo.cached(_orderId))!.picks.single.pick.id;
    serverReturns(
      _order(
        taken: 5,
        picks: [
          PickingPick(
            id: pickId,
            lineId: _lineId,
            boxId: _boxId,
            cellAddress: 'A-1',
            productionDate: '01-10-2026',
            qty: 5,
          ),
        ],
      ),
    );
    final view = (await repo.order(_orderId)).right;

    expect(view.taken(view.order.lines.single), 5);
    expect(view.picksOf(_lineId), hasLength(1));
  });

  test('отклонённый пик снимается с экрана', () async {
    serverReturns(_order());
    await repo.order(_orderId);
    when(() => sync.sendOne(any())).thenAnswer(
      (_) async => const Left(Failure.rejected('больше, чем осталось собрать')),
    );

    final res = await repo.pick(_request);

    expect(res.left, isA<RejectedFailure>());
    final view = (await repo.cached(_orderId))!;
    expect(view.taken(view.order.lines.single), 0);
    expect(view.picksOf(_lineId), isEmpty);
  });

  test('возврат своего неотправленного пика снимает его из очереди', () async {
    serverReturns(_order());
    await repo.order(_orderId);
    await repo.pick(_request);
    final pick = (await repo.cached(_orderId))!.picks.single.pick;

    final res = await repo.unpick(_orderId, pick);

    expect(res.isRight, isTrue);
    expect(await outbox.pendingCount(), 0);
    final view = (await repo.cached(_orderId))!;
    expect(view.taken(view.order.lines.single), 0);
  });

  test('возврат пика с сервера без связи - picking_unpick в очереди', () async {
    const pick = PickingPick(
      id: '55555555-5555-4555-8555-555555555555',
      lineId: _lineId,
      boxId: _boxId,
      cellAddress: 'A-1',
      productionDate: '01-10-2026',
      qty: 3,
    );
    serverReturns(_order(taken: 3, picks: [pick]));
    await repo.order(_orderId);

    await repo.unpick(_orderId, pick);

    final op = (await outbox.pending()).single;
    expect(op.kind.wire, 'picking_unpick');
    expect(op.payload, {'pick_id': pick.id});
    final view = (await repo.cached(_orderId))!;
    expect(view.taken(view.order.lines.single), 0);
    expect(view.picksOf(_lineId).single.returnPending, isTrue);
  });

  test('новый короб становится текущим', () async {
    serverReturns(_order());
    await repo.order(_orderId);
    when(() => api.addBox(_orderId, any())).thenAnswer(
      (inv) async => Right(
        PickingBox(loadUnitId: inv.positionalArguments[1] as String, seq: 2),
      ),
    );

    final box = (await repo.addBox(_orderId)).right;

    final view = (await repo.cached(_orderId))!;
    expect(view.currentBoxId, box.loadUnitId);
    expect(view.boxSeq(box.loadUnitId), 2);
  });
}
