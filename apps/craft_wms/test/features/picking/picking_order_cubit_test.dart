import 'dart:async';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/features/picking/domain/picking_models.dart';
import 'package:craft_wms/features/picking/domain/picking_repository.dart';
import 'package:craft_wms/features/picking/domain/picking_view.dart';
import 'package:craft_wms/features/picking/presentation/bloc/picking_order_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements PickingRepository {}

class _MockOutbox extends Mock implements OutboxRepository {}

class _FakeRequest extends Fake implements PickRequest {}

PickingOrderView _view() => PickingOrderView.build(
  PickingOrderDraft(
    order: const PickingOrder(
      id: 'o1',
      number: 1,
      registryDate: '2026-11-09',
      status: PickingStatus.inProgress,
      mine: true,
    ),
    fetchedAt: DateTime(2026, 11, 9),
  ),
  states: const {},
);

const _request = PickRequest(
  orderId: 'o1',
  lineId: 'l1',
  sourceCellId: 'c1',
  cellAddress: 'A-1',
  productionDate: '01-10-2026',
  qty: 1,
);

class _MockOperation extends Mock implements OutboxOperation {}

/// Отклонённый сервером пик заказа [orderId].
OutboxOperation _rejectedPick(String id, {String orderId = 'o1'}) {
  final op = _MockOperation();
  when(() => op.operationId).thenReturn(id);
  when(() => op.kind).thenReturn(OutboxKind.pickingPick);
  when(() => op.payload).thenReturn({'order_id': orderId});
  when(() => op.lastError).thenReturn('больше, чем осталось собрать');
  return op;
}

/// Заказ сборки на экране (P9-06, ADHOC-63): пик сразу из слепка, отказ сервера - из очереди
/// отказов, заказ с сервера - после паузы.
void main() {
  late _MockRepo repo;
  late _MockOutbox outbox;
  late StreamController<List<OutboxOperation>> rejected;

  setUpAll(() => registerFallbackValue(_FakeRequest()));

  setUp(() {
    repo = _MockRepo();
    outbox = _MockOutbox();
    rejected = StreamController<List<OutboxOperation>>.broadcast();
    when(() => outbox.watchPendingCount()).thenAnswer((_) => Stream.value(0));
    when(() => outbox.watchRejected()).thenAnswer((_) => rejected.stream);
    when(() => repo.order('o1')).thenAnswer((_) async => Right(_view()));
    when(
      () => repo.cached('o1', offline: any(named: 'offline')),
    ).thenAnswer((_) async => _view());
  });

  tearDown(() => rejected.close());

  Future<OrderNotice?> pickWith(Either<Failure, void> result) async {
    when(() => repo.pick(any())).thenAnswer((_) async => result);
    final cubit = PickingOrderCubit(repo, outbox, 'o1');
    await cubit.load();
    OrderNotice? notice;
    final sub = cubit.stream.listen((s) => notice ??= s.notice);
    await cubit.pick(_request);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await cubit.close();
    return notice;
  }

  test(
    'пик принят на терминале - «взято» сразу, заказ с сервера не ждётся',
    () async {
      final n = await pickWith(const Right(null));
      expect(n, isA<OrderNoticeDone>());
      expect((n! as OrderNoticeDone).queued, isFalse);
      // Только загрузка экрана: перечитывание - после паузы.
      verify(() => repo.order('o1')).called(1);
      verify(() => repo.cached('o1', offline: false)).called(1);
    },
  );

  test('пик не поставлен - причина', () async {
    final n = await pickWith(
      const Left(Failure.unknown('нет короба отгрузки')),
    );
    expect(n, isA<OrderNoticeFailed>());
  });

  test('заказ перечитывается один раз после паузы в сканах', () async {
    when(() => repo.pick(any())).thenAnswer((_) async => const Right(null));
    final cubit = PickingOrderCubit(repo, outbox, 'o1');
    await cubit.load();

    for (var i = 0; i < 3; i++) {
      await cubit.pick(_request);
    }
    verify(() => repo.order('o1')).called(1);
    await Future<void>.delayed(
      PickingOrderCubit.reloadPause + const Duration(milliseconds: 200),
    );

    verify(() => repo.order('o1')).called(1);
    await cubit.close();
  });

  test(
    'отказ сервера пику в фоне - причина дословно, старые отказы молчат',
    () async {
      final cubit = PickingOrderCubit(repo, outbox, 'o1');
      await cubit.load();
      final notices = <OrderNotice>[];
      // Как экран: подсказка показывается один раз и снимается.
      final sub = cubit.stream.listen((s) {
        if (s.notice == null) return;
        notices.add(s.notice!);
        cubit.clearNotice();
      });

      rejected.add([_rejectedPick('old')]);
      await Future<void>.delayed(Duration.zero);
      rejected.add([
        _rejectedPick('new'),
        _rejectedPick('other', orderId: 'o2'),
        _rejectedPick('old'),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(notices, hasLength(1));
      expect(
        (notices.single as OrderNoticeRejected).reason,
        'больше, чем осталось собрать',
      );
      await sub.cancel();
      await cubit.close();
    },
  );
}
