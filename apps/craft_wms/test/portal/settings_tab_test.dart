import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/internal_warehouses_repository.dart';
import 'package:craft_wms/portal/data/problem_reasons_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/settings/problem_reasons_section.dart';
import 'package:craft_wms/portal/presentation/widgets/settings/warehouses_section.dart';
import 'package:craft_wms/portal/presentation/widgets/shell/sidebar_menu_item.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/settings_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_choice.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWarehouses extends Mock implements InternalWarehousesRepository {}

class _MockReasons extends Mock implements ProblemReasonsRepository {}

const _profile = Profile(
  userId: 'u1',
  login: '',
  fullName: 'Офис Оператор',
  role: 'employee',
  position: 'Оператор',
  rights: [],
);

/// ADHOC-56: «Настройки» по шаблону Shopify Polaris — группы разделов, одна на экране; раскладка
/// по ширине вкладки: широко — список групп слева, узко — варианты выбора сверху.
void main() {
  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    final warehouses = _MockWarehouses();
    final reasons = _MockReasons();
    getIt
      ..registerSingleton<InternalWarehousesRepository>(warehouses)
      ..registerSingleton<ProblemReasonsRepository>(reasons);
    when(warehouses.list).thenAnswer((_) async => const Right([]));
    when(
      reasons.list,
    ).thenAnswer((_) async => const Right((reasons: [], resolutions: [])));
  });

  tearDown(getIt.reset);

  Future<void> pump(WidgetTester tester, {required double width}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SettingsTab(
            warehouses: true,
            problemReasons: true,
            users: false,
            profile: _profile,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('широко — группы списком слева, на экране одна группа', (
    tester,
  ) async {
    await pump(tester, width: 1200);

    expect(find.byType(SidebarMenuItem), findsNWidgets(2));
    expect(find.byType(PortalChoice), findsNothing);
    expect(find.byType(WarehousesSection), findsOneWidget);
    expect(find.byType(ProblemReasonsSection), findsNothing);

    await tester.tap(find.text(t.portal.settings.groupProblems));
    await tester.pumpAndSettle();
    expect(find.byType(WarehousesSection), findsNothing);
    expect(find.byType(ProblemReasonsSection), findsOneWidget);
  });

  testWidgets('узко — группы вариантами выбора сверху, без переполнения', (
    tester,
  ) async {
    await pump(tester, width: 390);

    expect(find.byType(SidebarMenuItem), findsNothing);
    expect(find.byType(PortalChoice), findsNWidgets(2));

    await tester.tap(find.text(t.portal.settings.groupProblems));
    await tester.pumpAndSettle();
    expect(find.byType(ProblemReasonsSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
