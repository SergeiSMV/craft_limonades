import 'package:craft_wms/core/error/failure.dart';
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

/// Заказ сборки на экране (P9-06): исход пика - подсказкой.
void main() {
  late _MockRepo repo;
  late _MockOutbox outbox;

  setUpAll(() => registerFallbackValue(_FakeRequest()));

  setUp(() {
    repo = _MockRepo();
    outbox = _MockOutbox();
    when(() => outbox.watchPendingCount()).thenAnswer((_) => Stream.value(0));
    when(() => repo.order('o1')).thenAnswer((_) async => Right(_view()));
    when(() => repo.cached('o1')).thenAnswer((_) async => _view());
  });

  Future<OrderNotice?> pickWith(Either<Failure, void> result) async {
    when(() => repo.pick(any())).thenAnswer((_) async => result);
    final cubit = PickingOrderCubit(repo, outbox, 'o1');
    await cubit.load();
    OrderNotice? notice;
    final sub = cubit.stream.listen((s) => notice ??= s.notice);
    await cubit.pick(_request);
    await sub.cancel();
    await cubit.close();
    return notice;
  }

  test('сервер принял пик - «взято»', () async {
    final n = await pickWith(const Right(null));
    expect(n, isA<OrderNoticeDone>());
    expect((n! as OrderNoticeDone).queued, isFalse);
  });

  test('без связи - пик в очереди', () async {
    final n = await pickWith(const Left(Failure.network()));
    expect((n! as OrderNoticeDone).queued, isTrue);
  });

  test('отказ по существу - причина дословно', () async {
    final n = await pickWith(
      const Left(Failure.rejected('больше, чем осталось собрать')),
    );
    expect((n! as OrderNoticeRejected).reason, 'больше, чем осталось собрать');
  });
}
