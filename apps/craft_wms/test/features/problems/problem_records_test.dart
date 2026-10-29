import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/problems/data/problem_records_repository_impl.dart';
import 'package:craft_wms/features/problems/domain/problem_records.dart';
import 'package:craft_wms/features/problems/presentation/bloc/resolved_problems_cubit.dart';
import 'package:craft_wms/features/problems/presentation/pages/problem_record_page.dart';
import 'package:craft_wms/features/problems/presentation/widgets/resolved/resolved_feed.dart';
import 'package:craft_wms/features/problems/presentation/widgets/records/record_days.dart';
import 'package:craft_wms/features/problems/presentation/widgets/records/record_format.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/problem_photo_stubs.dart';

class _MockRepo extends Mock implements ProblemRecordsRepository {}

/// Эталон ответа ленты — общий с сервером (`problem_http_test.go`): сервер обязан отдавать
/// ровно его, терминал — разбирать.
const _fixturePath =
    '../backend/internal/handler/testdata/problems_resolved.json';

ProblemRecord problem(String id, String resolvedAt, {String? box}) =>
    ProblemRecord(
      id: id,
      createdAt: DateTime.utc(2026, 10, 21, 9),
      createdBy: 'Иванов Иван',
      cellAddress: 'M1-1-1-1',
      loadUnitId: box,
      reason: 'expired',
      fromWarehouse: 'Основной',
      toWarehouse: 'Брак',
      items: const [
        ProblemRecordItem(
          goodName: 'Кальмар',
          productionDate: '2026-09-01',
          qty: '12.000',
          cellAddress: 'M1-1-1-1',
        ),
      ],
      decision: ProblemDecision.supplierReturn,
      supplierName: 'ИП Березин',
      returnTaskNumber: 7,
      resolvedBy: 'Петрова Анна',
      resolvedAt: resolvedAt,
    );

/// ADHOC-34: «Завершённые» проблемы склада на ТСД — разбор эталона ответа, лента с подгрузкой
/// и фильтром, подписи решения, карточка.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.useDeviceLocale();
    registerProblemPhotoStubs();
  });
  setUpAll(() => registerFallbackValue(const ResolvedProblemsQuery()));

  test('эталон ответа разбирается: проблема, товар, решение офиса', () {
    final raw = jsonDecode(File(_fixturePath).readAsStringSync()) as List;
    final p = problemRecordFromJson(raw.single as Map<String, dynamic>);

    expect(p.id, '7e000000-0000-4000-8000-000000000001');
    expect(p.number, 1);
    expect(numberLabel(p), t.problems.numberLine(number: 'ПБ-000001'));
    expect(
      (p.cellAddress, p.loadUnitId, p.reason),
      ('M1-1-1-1', null, 'breakage'),
    );
    expect((p.fromWarehouse, p.toWarehouse), ('Основной', 'Брак'));
    expect(p.comment, 'разбита при снятии с полки');
    expect(p.items.single.goodName, 'Кальмар');
    expect(p.items.single.qty, '2.000');
    expect(p.decision, ProblemDecision.writeOff);
    expect((p.docNumber, p.docDate), ('СП-17', '2026-10-21'));
    expect((p.supplierName, p.returnTaskNumber), (null, null));
    expect(p.resolvedBy, 'Петрова Анна');
    expect(
      p.resolvedAt,
      '2026-10-21T11:40:00Z',
      reason: 'курсор уходит на сервер строкой, как пришёл',
    );
  });

  test(
    'подписи решения: документ 1С, возврат с заданием, «разместить» без подробностей',
    () {
      final raw = jsonDecode(File(_fixturePath).readAsStringSync()) as List;
      final writeOff = problemRecordFromJson(
        raw.single as Map<String, dynamic>,
      );
      expect(decisionLabel(writeOff.decision), t.problems.decisionWriteOff);
      expect(outcomeLabel(writeOff), t.problems.outcomeWriteOff);
      expect(executionLines(writeOff), [
        t.problems.docLine(number: 'СП-17', date: '21.10.2026'),
      ]);
      expect(
        executedMeta(writeOff),
        contains('Петрова Анна'),
        reason: 'списание исполняет «Провести» — решивший',
      );
      expect(reasonLabelOf(writeOff.reason), t.problems.reasonBreakage);
      expect(subjectLabel(writeOff), 'Кальмар');
      expect(
        subjectLines(writeOff),
        [
          t.problems.batchLine(date: '01.09.2026'),
          t.problems.qtyLine(qty: '2'),
        ],
        reason: 'партия и количество — каждое своей строкой',
      );

      final ret = problem(
        'p1',
        '2026-10-21T10:00:00Z',
        box: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
      );
      expect(decisionLines(ret), [
        t.problems.supplierLine(supplier: 'ИП Березин'),
        t.problems.taskLine(number: 'ЗД-000007'),
      ]);
      expect(outcomeLabel(ret), t.problems.outcomeAwaiting);
      expect(executedMeta(ret), isNull, reason: 'возврат ещё не отгружен');
      expect(subjectLabel(ret), t.problems.box(code: '9FA0 B1C2'));
      expect(subjectLines(ret), [t.problems.positionsLine(count: 1)]);
      expect(
        reasonLabelOf('новая'),
        'новая',
        reason: 'незнакомая причина — как есть',
      );
    },
  );

  group('лента', () {
    List<ProblemRecord> page(int n, {int from = 0}) => [
      for (var i = from; i < from + n; i++)
        problem(
          'p$i',
          '2026-10-21T10:${(59 - i % 60).toString().padLeft(2, '0')}:00Z',
        ),
    ];

    test('следующая страница — после последней показанной записи', () async {
      final repo = _MockRepo();
      final first = page(ResolvedProblemsCubit.pageSize);
      when(
        () => repo.resolved(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => Right(first));
      when(
        () => repo.resolved(
          query: any(named: 'query'),
          after: first.last,
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => Right(page(2, from: 100)));
      final cubit = ResolvedProblemsCubit(repo);

      await cubit.load();
      expect(cubit.state.hasMore, isTrue);
      await cubit.loadMore();

      expect(cubit.state.items, hasLength(ResolvedProblemsCubit.pageSize + 2));
      expect(cubit.state.hasMore, isFalse, reason: 'короткая страница — конец');
      await cubit.close();
    });

    test('фильтр — период уходит в запрос, лента с первой страницы', () async {
      final repo = _MockRepo();
      ResolvedProblemsQuery? asked;
      when(
        () => repo.resolved(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((inv) async {
        asked = inv.namedArguments[#query] as ResolvedProblemsQuery;
        return const Right([]);
      });
      final cubit = ResolvedProblemsCubit(repo);

      await cubit.setFilter(
        CompletedFilter(
          from: DateTime(2026, 10, 1),
          to: DateTime(2026, 10, 21),
        ),
      );

      expect(
        (asked?.from, asked?.to),
        (DateTime(2026, 10, 1), DateTime(2026, 10, 21)),
      );
      expect(cubit.state.status, ResolvedStatus.loaded);
      await cubit.close();
    });

    test('без связи — ошибка «только при связи»', () async {
      final repo = _MockRepo();
      when(
        () => repo.resolved(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => const Left(Failure.network()));
      final cubit = ResolvedProblemsCubit(repo);
      await cubit.load();
      expect(cubit.state.status, ResolvedStatus.error);
      await cubit.close();
    });

    test('разделители по дням решения', () {
      final entries = groupRecordsByDay([
        problem('a', '2026-10-21T10:00:00'),
        problem('b', '2026-10-21T09:00:00'),
        problem('c', '2026-10-20T18:00:00'),
      ]);
      expect(entries.whereType<RecordDay>().length, 2);
      expect(entries, hasLength(5));
    });
  });

  testWidgets('лента: запись с решением; без связи — подсказка', (
    tester,
  ) async {
    final repo = _MockRepo();
    var online = true;
    when(
      () => repo.resolved(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => online
          ? Right([problem('p1', DateTime.now().toUtc().toIso8601String())])
          : const Left(Failure.network()),
    );
    final cubit = ResolvedProblemsCubit(repo);
    await tester.pumpWidget(
      BlocProvider.value(
        value: cubit,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(body: ResolvedFeed()),
        ),
      ),
    );
    await cubit.load();
    await tester.pumpAndSettle();
    expect(find.text(t.problems.outcomeAwaiting), findsOneWidget);
    expect(find.text('Кальмар'), findsOneWidget);
    // Без номера — своя неотправленная: номер выдаёт сервер (ADHOC-55).
    expect(find.text(t.problems.numberPending), findsOneWidget);
    expect(find.text(t.problems.placeLine(place: 'M1-1-1-1')), findsOneWidget);

    online = false;
    await cubit.load();
    await tester.pumpAndSettle();
    expect(find.text(t.problems.resolvedOnlineOnly), findsOneWidget);
    await cubit.close();
  });

  test('отгрузка возврата из ответа — исполнитель и время', () {
    final p = problemRecordFromJson({
      'id': 'p1',
      'created_at': '2026-10-21T09:00:00Z',
      'cell_address': 'M1-4-3-2',
      'reason': 'spoilage',
      'from_warehouse': 'Основной',
      'to_warehouse': 'Брак',
      'decision': 'supplier_return',
      'supplier_name': 'ИП Лапушкин',
      'return_task_number': 8,
      'resolved_by': 'Администратор',
      'resolved_at': '2026-10-21T13:27:00Z',
      'shipped_by': 'Иванов Иван',
      'shipped_at': '2026-10-21T15:00:00Z',
    });
    expect(p.awaitingShipment, isFalse);
    expect(outcomeLabel(p), t.problems.outcomeShipped);
    expect(executedMeta(p), contains('Иванов Иван'));
  });

  testWidgets(
    'карточка: проблема, решение, исполнение — по порядку, без «Товара»',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ProblemRecordPage(
            problem: problem('p1', '2026-10-21T10:00:00Z'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final problemY = tester
          .getTopLeft(find.text(t.problems.sectionProblem))
          .dy;
      final decisionY = tester
          .getTopLeft(find.text(t.problems.sectionDecision))
          .dy;
      final executionY = tester
          .getTopLeft(find.text(t.problems.sectionExecution))
          .dy;
      expect(problemY < decisionY && decisionY < executionY, isTrue);
      expect(find.text(t.problems.decisionSupplierReturn), findsOneWidget);
      expect(find.text(t.problems.outcomeAwaiting), findsOneWidget);
      expect(
        find.text(t.problems.supplierLine(supplier: 'ИП Березин')),
        findsOneWidget,
      );
      expect(find.text(t.problems.taskLine(number: 'ЗД-000007')), findsOneWidget);
      expect(
        find.text(t.problems.batchLine(date: '01.09.2026')),
        findsOneWidget,
      );
      expect(find.text(t.problems.qtyLine(qty: '12')), findsOneWidget);
      expect(
        find.text(t.problems.reasonLine(reason: t.problems.reasonExpired)),
        findsOneWidget,
      );
      expect(
        find.text(t.problems.warehousesLine(from: 'Основной', to: 'Брак')),
        findsOneWidget,
      );
      expect(
        find.text('Кальмар'),
        findsOneWidget,
        reason: 'раздела «Товар» нет',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'фото в карточке: у открытой — «Сфотографировать», у решённой — только просмотр',
    (tester) async {
      final open = ProblemRecord(
        id: 'p-open',
        createdAt: DateTime.utc(2026, 10, 24, 9),
        createdBy: 'Иванов Иван',
        cellAddress: 'С-Н-П',
        reason: 'foreign_mark',
        fromWarehouse: 'Основной',
        toWarehouse: 'Изолятор',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ProblemRecordPage(problem: open),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.problems.photos(count: 0, max: 3)), findsOneWidget);
      expect(find.text(t.problems.takePhoto), findsOneWidget);

      // Карточки открываются своими маршрутами; в тесте — пустой кадр между ними, иначе
      // Flutter переиспользовал бы элемент страницы вместе с cubit фото прежней карточки.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ProblemRecordPage(
            problem: problem('p1', '2026-10-21T10:00:00Z'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.problems.takePhoto), findsNothing);
    },
  );
}
