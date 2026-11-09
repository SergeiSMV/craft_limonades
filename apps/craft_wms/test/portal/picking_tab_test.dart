import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/portal/domain/picking/picking_order.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/picking_tab.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements PickingOrdersRepository {}

PickingOrderSummary _order({
  PickingStatus status = PickingStatus.inProgress,
  String id = 'o1',
  int number = 9,
  bool outOfSync = false,
  bool changedAfterShipment = false,
}) => PickingOrderSummary(
  id: id,
  number: number,
  registryDate: DateTime(2026, 11, 9),
  invoiceNumber: '20961',
  orderNumber: '15512',
  orderDate: null,
  direction: 'Рязань',
  client: 'ИП Суслова',
  address: '',
  status: status,
  isPartial: false,
  hasUnknown: false,
  deleted: false,
  changedAfterShipment: changedAfterShipment,
  outOfSync: outOfSync,
  assigneeName: status == PickingStatus.inProgress ? 'Анна' : '',
  takenAt: null,
  pickedByName: '',
  pickedAt: null,
  shippedAt: null,
  lines: 1,
  planQty: 3,
  factQty: 1,
  boxes: 1,
);

PickingOrderDetail _detail(PickingStatus status) => PickingOrderDetail(
  order: _order(status: status),
  lines: const [
    PickingOrderLine(
      lineNo: 1,
      goodCode: '00000016147',
      goodName: 'Лимонад',
      uom: 'шт',
      czMarked: false,
      batchDate: null,
      registryCell: '',
      cellAddress: '',
      planQty: 3,
      factQty: 1,
      removed: false,
      shortage: false,
      facts: [],
    ),
  ],
  boxes: const [],
  changes: const [],
);

/// P8-03: вкладка «Сборка-отгрузка» — дата по умолчанию завтра, заказ со статусом, окно
/// деталей и снятие с исполнителя после подтверждения; без права снятия кнопки нет.
void main() {
  late _MockRepo repo;
  var status = PickingStatus.inProgress;

  setUpAll(() => registerFallbackValue(DateTime(2026)));

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    getIt.registerSingleton(DataVersions());
    repo = _MockRepo();
    getIt.registerSingleton<PickingOrdersRepository>(repo);
    status = PickingStatus.inProgress;
    when(
      () => repo.orders(any()),
    ).thenAnswer((_) async => Right([_order(status: status)]));
    when(
      () => repo.order('o1'),
    ).thenAnswer((_) async => Right(_detail(status)));
    when(() => repo.release('o1')).thenAnswer((_) async {
      status = PickingStatus.newOrder;
      return const Right(null);
    });
  });

  tearDown(getIt.reset);

  Future<void> pump(WidgetTester tester, {required bool canRelease}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickingTab(
            canView: true,
            canLoad: false,
            canDownload: true,
            canRelease: canRelease,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('завтра по умолчанию; снять с исполнителя из окна деталей', (
    tester,
  ) async {
    await pump(tester, canRelease: true);
    final now = DateTime.now();
    final asked = verify(() => repo.orders(captureAny())).captured.single;
    expect(asked, DateTime(now.year, now.month, now.day + 1));

    final p = t.portal.picking;
    expect(find.text('СБ-000009'), findsOneWidget);
    expect(find.text(p.statusInProgress), findsOneWidget);

    await tester.tap(find.text('СБ-000009'));
    await tester.pumpAndSettle();
    expect(find.text(p.linePlan(qty: 3, uom: 'шт')), findsOneWidget);

    await tester.tap(find.text(p.releaseButton));
    await tester.pumpAndSettle();
    expect(find.text(p.releaseTitle), findsOneWidget);
    await tester.tap(find.text(p.releaseConfirm));
    await tester.pumpAndSettle();

    verify(() => repo.release('o1')).called(1);
    // Заказ снова «новый»: снимать больше нечего.
    expect(find.text(p.releaseButton), findsNothing);
  });

  testWidgets('сверка с 1С: пометки и отбор «Только расходится с 1С»', (
    tester,
  ) async {
    // P9-08: отгружен пустым - расходится с 1С; второй приведён реестром после отгрузки.
    when(() => repo.orders(any())).thenAnswer(
      (_) async => Right([
        _order(status: PickingStatus.shipped, outOfSync: true),
        _order(
          status: PickingStatus.shipped,
          id: 'o2',
          number: 10,
          changedAfterShipment: true,
        ),
      ]),
    );
    await pump(tester, canRelease: false);
    final p = t.portal.picking;
    expect(find.text(p.badgeOutOfSync), findsOneWidget);
    expect(find.text(p.badgeSynced), findsOneWidget);

    await tester.tap(find.text(p.onlyOutOfSync(count: 1)));
    await tester.pumpAndSettle();
    expect(find.text('СБ-000009'), findsOneWidget);
    expect(find.text('СБ-000010'), findsNothing);
  });

  testWidgets('без права снятия кнопки нет', (tester) async {
    await pump(tester, canRelease: false);
    await tester.tap(find.text('СБ-000009'));
    await tester.pumpAndSettle();
    expect(find.text(t.portal.picking.releaseButton), findsNothing);
  });
}
