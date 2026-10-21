import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/problems_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/problems_tab.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements ProblemsRepository {}

PortalProblem problem(
  String id, {
  required String reason,
  required List<String> decisions,
  bool resolved = false,
}) => PortalProblem(
  id: id,
  createdAt: DateTime.utc(2026, 10, 21, 8),
  createdBy: 'Иванов',
  cellAddress: 'A-1',
  loadUnitId: '',
  reason: reason,
  comment: '',
  mark: '',
  fromWarehouse: 'Основной',
  toWarehouse: 'Брак',
  items: const [
    PortalProblemItem(
      goodCode: '00-1',
      goodName: 'Сыр жареный',
      productionDate: '2026-08-21',
      qty: 2,
      cellAddress: 'A-1',
    ),
  ],
  decisions: decisions,
  suggestedSupplierId: '',
  resolved: resolved,
  decision: resolved ? ProblemDecision.place : '',
  docNumber: '',
  docDate: '',
  supplierName: '',
  returnTaskNumber: 0,
  resolvedBy: resolved ? 'Петров' : '',
  resolvedAt: resolved ? DateTime.utc(2026, 10, 21, 9) : null,
);

/// P6-07-3: вкладка «Проблемы склада» — открытые по умолчанию, решение списанием из диалога.
void main() {
  late _MockRepo repo;

  setUpAll(() {
    registerFallbackValue((
      decision: '',
      docNumber: '',
      docDate: '',
      supplierId: '',
    ));
  });

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    repo = _MockRepo();
    getIt.registerSingleton<ProblemsRepository>(repo);
    when(() => repo.list()).thenAnswer(
      (_) async => Right([
        problem(
          'p1',
          reason: 'breakage',
          decisions: [ProblemDecision.writeOff],
        ),
        problem(
          'p2',
          reason: 'foreign_mark',
          decisions: [ProblemDecision.place, ProblemDecision.supplierReturn],
          resolved: true,
        ),
      ]),
    );
    when(
      () => repo.resolve(any(), any()),
    ).thenAnswer((_) async => const Right(null));
  });

  tearDown(getIt.reset);

  testWidgets('открытые сверху; бой — списание с документом 1С', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProblemsTab())),
    );
    await tester.pumpAndSettle();

    // Фильтр по умолчанию — открытые: решённой не видно.
    expect(find.text(t.portal.problems.reasonBreakage), findsOneWidget);
    expect(find.text(t.portal.problems.reasonForeignMark), findsNothing);

    await tester.tap(find.text(t.portal.problems.resolve));
    await tester.pumpAndSettle();
    // Единственное допустимое решение выбрано сразу; без номера документа не проводится.
    await tester.tap(find.text(t.portal.problems.post));
    await tester.pumpAndSettle();
    expect(find.text(t.portal.problems.needDoc), findsOneWidget);
    verifyNever(() => repo.resolve(any(), any()));

    await tester.enterText(find.byType(TextField).last, 'СП-17');
    await tester.tap(find.text(t.portal.problems.post));
    await tester.pumpAndSettle();

    final captured = verify(() => repo.resolve('p1', captureAny())).captured;
    final r = captured.single as ProblemResolution;
    expect(r.decision, ProblemDecision.writeOff);
    expect(r.docNumber, 'СП-17');
    expect(r.docDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    verify(() => repo.list()).called(2); // после проведения список перечитан
  });
}
