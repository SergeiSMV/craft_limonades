import 'package:craft_wms/core/load_unit/load_unit_code.dart';
import 'package:craft_wms/core/printer/picking_box_label.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/features/picking/domain/picking_repository.dart';
import 'package:craft_wms/features/picking/domain/picking_shipment.dart';
import 'package:craft_wms/features/picking/presentation/bloc/picking_shipment_cubit.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements PickingRepository {}

class _MockPrinter extends Mock implements PrinterService {}

class _FakeLabel extends Fake implements PickingBoxLabel {}

const _b1 = '11111111-1111-4111-8111-111111111111';
const _b2 = '22222222-2222-4222-8222-222222222222';

PickingShipment _shipment({int printed = 0, String status = 'picked'}) =>
    PickingShipment(
      id: 'o1',
      number: 7,
      registryDate: '2026-11-09',
      invoiceNumber: '20961',
      orderNumber: '15512',
      status: status,
      qty: 9,
      boxes: [
        PickingShipmentBox(
          loadUnitId: _b1,
          seq: 1,
          qty: 8,
          labelsPrinted: printed,
        ),
        const PickingShipmentBox(loadUnitId: _b2, seq: 2, qty: 1),
      ],
    );

/// Ярлыки и отгрузка собранного заказа (P9-07).
void main() {
  late _MockRepo repo;
  late _MockPrinter printer;

  setUpAll(() => registerFallbackValue(_FakeLabel()));

  setUp(() {
    repo = _MockRepo();
    printer = _MockPrinter();
    when(() => printer.printPickingBoxLabel(any())).thenAnswer((_) async {});
  });

  test(
    'печать - только ещё не напечатанные ярлыки, счёт - через сервер',
    () async {
      when(
        () => repo.labels('o1', [_b2]),
      ).thenAnswer((_) async => Right(_shipment(printed: 1)));
      final cubit = PickingShipmentCubit(repo, printer, 'o1');
      await cubit.load(shipment: _shipment(printed: 1));
      await cubit.printLabels();
      verify(() => repo.labels('o1', [_b2])).called(1);
      verify(() => printer.printPickingBoxLabel(any())).called(1);
      expect(cubit.state.notice, isA<ShipmentNoticePrinted>());
    },
  );

  test(
    'скан всех ярлыков отгружает заказ; чужой и повторный - подсказка',
    () async {
      when(
        () => repo.ship('o1', any()),
      ).thenAnswer((_) async => Right(_shipment(status: 'shipped')));
      final cubit = PickingShipmentCubit(repo, printer, 'o1');
      await cubit.load(shipment: _shipment());

      await cubit.scan(
        encodeLoadUnitPayload('33333333-3333-4333-8333-333333333333'),
      );
      expect((cubit.state.notice! as ShipmentNoticeScanned).seq, isNull);

      await cubit.scan(encodeLoadUnitPayload(_b1));
      await cubit.scan(encodeLoadUnitPayload(_b1));
      expect((cubit.state.notice! as ShipmentNoticeScanned).again, isTrue);
      verifyNever(() => repo.ship(any(), any()));

      await cubit.scan(encodeLoadUnitPayload(_b2));
      final sent =
          verify(() => repo.ship('o1', captureAny())).captured.single
              as List<String>;
      expect(sent.toSet(), {_b1, _b2});
      expect(cubit.state.notice, isA<ShipmentNoticeShipped>());
      expect(cubit.state.shipment!.shipped, isTrue);
    },
  );
}
