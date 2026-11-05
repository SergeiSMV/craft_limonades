import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/problems_repository.dart';
import 'package:craft_wms/portal/presentation/pages/portal_shell.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockProblems extends Mock implements ProblemsRepository {}

Profile operator({
  List<String> rights = const [
    'portal.problems.view',
    'portal.problems.resolve',
  ],
}) => Profile(
  userId: 'u1',
  login: '',
  fullName: 'Офис Оператор',
  role: 'employee',
  position: 'Оператор',
  rights: rights,
);

/// ADHOC-50: меню портала — по действиям должности. «Оператор» с действиями «Проблемы склада:
/// смотреть и решать» видит только «Проблемы склада»; без действий портала — в портал не
/// пускают.
void main() {
  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
    final problems = _MockProblems();
    getIt.registerSingleton<ProblemsRepository>(problems);
    when(problems.list).thenAnswer((_) async => const Right([]));
  });

  tearDown(getIt.reset);

  test('вход в портал — право «портал» и хоть один раздел', () {
    expect(PortalShell.hasSections(operator()), isTrue);
    expect(PortalShell.hasSections(operator(rights: ['problems'])), isFalse);
    expect(
      PortalShell.hasSections(operator(rights: ['portal', 'tsd'])),
      isFalse,
    );
  });

  testWidgets('оператор видит только «Проблемы склада» и свою должность', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Тестовый шрифт шире Inter: в полном масштабе пункты меню не влезают в сайдбар.
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1400, 900),
            textScaler: TextScaler.linear(0.5),
          ),
          child: PortalShell(profile: operator()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.portal.tabs.problems), findsWidgets);
    for (final hidden in [
      t.portal.tabs.nomenclature,
      t.portal.tabs.stock,
      t.portal.tabs.receipt,
      t.portal.tabs.stocktake,
      t.portal.tabs.cells,
      t.portal.tabs.movement,
      t.portal.tabs.settings,
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    expect(find.text('Оператор'), findsOneWidget);
  });
}
