import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/internal_warehouses/internal_warehouses_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_button.dart';
import 'package:craft_wms/portal/presentation/widgets/settings/warehouses_section.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements InternalWarehousesRepository {}

PortalWarehouse wh(
  String id,
  String name, {
  bool isDefault = false,
  bool isActive = true,
  bool inUse = false,
}) => PortalWarehouse(
  id: id,
  code: id.toUpperCase(),
  name: name,
  isDefault: isDefault,
  isActive: isActive,
  inUse: inUse,
);

/// ADHOC-29: раздел «Внутренние склады» в настройках портала.
void main() {
  late _MockRepo repo;

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
    repo = _MockRepo();
    getIt.registerSingleton<InternalWarehousesRepository>(repo);
    when(() => repo.list()).thenAnswer(
      (_) async => Right([
        wh('main', 'Основной', isDefault: true, inUse: true),
        wh('defect', 'Брак', inUse: true),
        wh('old', 'Старый', isActive: false),
      ]),
    );
  });

  tearDown(getIt.reset);

  Future<void> pump(WidgetTester tester, {double width = 1000}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: WarehousesSection())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('действий ровно столько, сколько позволено складу', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text(t.portal.warehouses.markDefault), findsOneWidget);
    expect(find.text(t.portal.warehouses.markHidden), findsOneWidget);
    // «Есть остаток» - у брака; у склада по умолчанию отметки «По умолчанию» достаточно.
    expect(find.text(t.portal.warehouses.markInUse), findsOneWidget);

    Iterable<String> tooltips() => tester
        .widgetList<PortalIconButton>(find.byType(PortalIconButton))
        .map((b) => b.tooltip);
    // Основной - только переименовать; брак - переименовать и скрыть (удалить нельзя: остаток);
    // старый - переименовать, вернуть и удалить.
    expect(tooltips(), [
      t.portal.warehouses.rename,
      t.portal.warehouses.rename,
      t.portal.warehouses.hide,
      t.portal.warehouses.rename,
      t.portal.warehouses.show,
      t.portal.warehouses.delete,
    ]);
  });

  testWidgets('скрыть - запрос на сервер и список перечитан; отказ - текстом', (
    tester,
  ) async {
    when(() => repo.update('defect', isActive: false)).thenAnswer(
      (_) async => Right(wh('defect', 'Брак', isActive: false, inUse: true)),
    );
    await pump(tester);

    await tester.tap(find.byTooltip(t.portal.warehouses.hide));
    await tester.pumpAndSettle();
    verify(() => repo.update('defect', isActive: false)).called(1);
    verify(() => repo.list()).called(2);

    when(() => repo.update('old', isActive: true)).thenAnswer(
      (_) async => const Left(
        Failure.server(409, 'склад по умолчанию нельзя скрыть или удалить'),
      ),
    );
    await tester.tap(find.byTooltip(t.portal.warehouses.show));
    await tester.pumpAndSettle();
    expect(
      find.text('склад по умолчанию нельзя скрыть или удалить'),
      findsOneWidget,
    );
  });

  testWidgets('на узком экране без переполнения', (tester) async {
    await pump(tester, width: 360);
    expect(tester.takeException(), isNull);
  });
}
