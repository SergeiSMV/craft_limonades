import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/presentation/bloc/cell_contents_cubit.dart';
import 'package:craft_wms/features/contents/presentation/bloc/load_unit_cubit.dart';
import 'package:craft_wms/features/contents/presentation/bloc/load_unit_history_cubit.dart';
import 'package:craft_wms/features/contents/presentation/pages/cell_contents_page.dart';
import 'package:craft_wms/features/contents/presentation/pages/load_unit_page.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contents_stubs.dart';
import '../../support/fake_scanner_service.dart';

/// Экраны «Ячейка» и «Короб» (P5-05): что видно со связью, без связи и когда показать нечего.
void main() {
  late FakeContentsRepository repo;
  late FakeLabelPrinter printer;
  final asOf = DateTime(2026, 10, 8, 14, 30);

  setUp(() {
    LocaleSettings.useDeviceLocale();
    // Экраны подписаны на аппаратный сканер — ему нужна раздача кодов.
    registerFakeScanner();
    repo = registerFakeContentsRepository();
    printer = FakeLabelPrinter();
    if (getIt.isRegistered<LoadUnitHistoryCubit>()) {
      getIt.unregister<LoadUnitHistoryCubit>();
    }
    getIt.registerFactory<LoadUnitHistoryCubit>(
      () => LoadUnitHistoryCubit(repo),
    );
    if (getIt.isRegistered<CellContentsCubit>()) {
      getIt.unregister<CellContentsCubit>();
    }
    if (getIt.isRegistered<LoadUnitCubit>()) getIt.unregister<LoadUnitCubit>();
    getIt.registerFactory<CellContentsCubit>(() => CellContentsCubit(repo));
    getIt.registerFactory<LoadUnitCubit>(() => LoadUnitCubit(repo, printer));
  });

  Widget wrap(Widget page) => MaterialApp(theme: buildAppTheme(), home: page);

  testWidgets(
    'ячейка без связи: адрес, короб с кодом ярлыка, россыпь, момент снимка',
    (tester) async {
      repo.cellResult = Right(
        Viewed(
          const CellView(
            cellId: 'c1',
            address: 'A-1-1',
            loadUnits: [
              LoadUnitView(
                id: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
                cellId: 'c1',
                live: true,
                lines: [
                  ContentLine(
                    goodId: 'g1',
                    productionDate: '01-09-2026',
                    qty: 12,
                  ),
                ],
                pending: true,
              ),
            ],
            loose: [
              ContentLine(
                goodId: 'g1',
                goodName: 'Кальмар',
                productionDate: '02-09-2026',
                qty: 3,
              ),
            ],
          ),
          FromSnapshot(asOf),
        ),
      );

      await tester.pumpWidget(
        wrap(const CellContentsPage(cellId: 'c1', address: 'A-1-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('A-1-1'), findsOneWidget);
      // Короткий код — последние 8 знаков UUID, две четвёрки.
      expect(find.text(t.contents.boxCode(code: '9FA0 B1C2')), findsOneWidget);
      expect(find.text(t.contents.pending), findsOneWidget);
      expect(find.text('Кальмар'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(
        find.text(t.contents.snapshotNote(time: '08.10 14:30')),
        findsOneWidget,
      );
    },
  );

  testWidgets('пустая ячейка со связью: «пуста», без подписи о снимке', (
    tester,
  ) async {
    repo.cellResult = const Right(
      Viewed(CellView(cellId: 'c1', address: 'A-1-1'), FreshFromServer()),
    );

    await tester.pumpWidget(
      wrap(const CellContentsPage(cellId: 'c1', address: 'A-1-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.contents.cellEmpty), findsOneWidget);
    expect(find.textContaining('Нет связи'), findsNothing);
  });

  testWidgets('короба нет в снимке: оговорка, что он мог появиться позже', (
    tester,
  ) async {
    repo.loadUnitResult = Right(Viewed(null, FromSnapshot(asOf)));

    await tester.pumpWidget(wrap(const LoadUnitPage(loadUnitId: 'x')));
    await tester.pumpAndSettle();

    expect(
      find.text(t.contents.notFoundSnapshot(time: '08.10 14:30')),
      findsOneWidget,
    );
  });

  testWidgets('нет связи и нет снимка: подсказка, а не «повторить»', (
    tester,
  ) async {
    repo.loadUnitResult = const Left(Failure.network());

    await tester.pumpWidget(wrap(const LoadUnitPage(loadUnitId: 'x')));
    await tester.pumpAndSettle();

    expect(find.text(t.contents.noConnection), findsOneWidget);
  });

  testWidgets('неживой короб со связью: объяснение и «не размещён»', (
    tester,
  ) async {
    repo.loadUnitResult = const Right(
      Viewed(LoadUnitView(id: 'x', live: false), FreshFromServer()),
    );

    await tester.pumpWidget(wrap(const LoadUnitPage(loadUnitId: 'x')));
    await tester.pumpAndSettle();

    expect(find.text(t.contents.notLive), findsOneWidget);
    expect(find.text(t.contents.notPlaced), findsOneWidget);
    expect(find.text(t.contents.boxEmpty), findsOneWidget);
  });

  group('карточка короба: перепечатка и история (P5-05-1)', () {
    const box = LoadUnitView(
      id: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
      cellId: 'c1',
      cellAddress: 'A-1-1',
      live: true,
    );

    testWidgets(
      '«Перепечатать ярлык» печатает этот короб и говорит об успехе',
      (tester) async {
        repo.loadUnitResult = const Right(Viewed(box, FreshFromServer()));

        await tester.pumpWidget(wrap(LoadUnitPage(loadUnitId: box.id)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.contents.reprint));
        await tester.pumpAndSettle();

        expect(printer.printed, [box.id]);
        expect(find.text(t.contents.reprinted), findsOneWidget);
      },
    );

    testWidgets('ошибка принтера — её текст, а не «отправлен»', (tester) async {
      repo.loadUnitResult = const Right(Viewed(box, FreshFromServer()));
      printer.error = 'Принтер не выбран';

      await tester.pumpWidget(wrap(LoadUnitPage(loadUnitId: box.id)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.contents.reprint));
      await tester.pumpAndSettle();

      expect(find.text('Принтер не выбран'), findsOneWidget);
      expect(find.text(t.contents.reprinted), findsNothing);
    });

    testWidgets('без связи: карточка из снимка, история — «только со связью»', (
      tester,
    ) async {
      repo.loadUnitResult = Right(Viewed(box, FromSnapshot(asOf)));
      repo.historyResult = const Left(Failure.network());

      await tester.pumpWidget(wrap(LoadUnitPage(loadUnitId: box.id)));
      await tester.pumpAndSettle();

      expect(find.text(t.contents.historyOnlineOnly), findsOneWidget);
      expect(find.text(t.contents.reprint), findsOneWidget);
    });

    testWidgets('история: кто принял, поставщик, перенос с ФИО', (
      tester,
    ) async {
      repo.loadUnitResult = const Right(Viewed(box, FreshFromServer()));
      repo.historyResult = Right(
        LoadUnitHistory(
          createdAt: DateTime(2026, 10, 8, 9),
          receipt: LoadUnitReceiptInfo(
            docNumber: 'ТН-1042/2',
            docDate: '01-10-2026',
            receivedBy: 'Иванов И.',
            supplier: 'ООО «Голсера»',
            postedAt: DateTime(2026, 10, 8, 10),
          ),
          moves: [
            LoadUnitMove(
              to: 'С-Н-П',
              kind: LoadUnitMoveKind.receipt,
              userName: 'Иванов И.',
              at: DateTime(2026, 10, 8, 10),
            ),
            LoadUnitMove(
              from: 'С-Н-П',
              to: 'A-1-1',
              kind: LoadUnitMoveKind.putaway,
              userName: 'Петров П.',
              at: DateTime(2026, 10, 8, 11, 5),
            ),
            // P6-04: перемещение подписывается перемещением, а не размещением.
            LoadUnitMove(
              from: 'A-1-1',
              to: 'B-2-2',
              kind: LoadUnitMoveKind.move,
              userName: 'Петров П.',
              at: DateTime(2026, 10, 13, 18, 50),
            ),
          ],
        ),
      );

      await tester.pumpWidget(wrap(LoadUnitPage(loadUnitId: box.id)));
      await tester.pumpAndSettle();

      // ADHOC-21: код — в заголовке экрана, в теле — место размещения, история свёрнута.
      expect(find.text(t.contents.boxCode(code: '9FA0 B1C2')), findsOneWidget);
      expect(find.text(t.contents.placedIn(address: 'A-1-1')), findsOneWidget);
      await tester.tap(find.text(t.contents.historyTitleCount(count: 3)));
      await tester.pumpAndSettle();

      expect(
        find.text(
          t.contents.historyDoc(number: 'ТН-1042/2', date: '01.10.2026'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.contents.historyReceived(name: 'Иванов И.')),
        findsOneWidget,
      );
      expect(
        find.text(t.contents.historySupplier(name: 'ООО «Голсера»')),
        findsOneWidget,
      );
      expect(
        find.text(t.contents.movePutaway(from: 'С-Н-П', to: 'A-1-1')),
        findsOneWidget,
      );
      expect(
        find.text(t.contents.moveMove(from: 'A-1-1', to: 'B-2-2')),
        findsOneWidget,
      );
      expect(
        find.text(
          t.contents.moveBy(name: 'Петров П.', time: '08.10.2026 11:05'),
        ),
        findsOneWidget,
      );
    });
  });

  // ADHOC-22: «нет связи» — только при обрыве связи; сервер с ошибкой — просто «данные на».
  testWidgets('снимок при живой связи подписан без «нет связи»', (
    tester,
  ) async {
    repo.cellResult = Right(
      Viewed(
        const CellView(cellId: 'c1', address: 'A-1-1'),
        FromSnapshot(asOf, offline: false),
      ),
    );

    await tester.pumpWidget(
      wrap(const CellContentsPage(cellId: 'c1', address: 'A-1-1')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(t.contents.snapshotAsOf(time: '08.10 14:30')),
      findsOneWidget,
    );
    expect(find.textContaining('Нет связи'), findsNothing);
  });
}
