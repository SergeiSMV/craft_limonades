import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/contents/presentation/bloc/cell_contents_cubit.dart';
import 'package:craft_wms/features/contents/presentation/bloc/load_unit_cubit.dart';
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
  final asOf = DateTime(2026, 10, 8, 14, 30);

  setUp(() {
    LocaleSettings.useDeviceLocale();
    // Экраны подписаны на аппаратный сканер — ему нужна раздача кодов.
    registerFakeScanner();
    repo = registerFakeContentsRepository();
    if (getIt.isRegistered<CellContentsCubit>()) {
      getIt.unregister<CellContentsCubit>();
    }
    if (getIt.isRegistered<LoadUnitCubit>()) getIt.unregister<LoadUnitCubit>();
    getIt.registerFactory<CellContentsCubit>(() => CellContentsCubit(repo));
    getIt.registerFactory<LoadUnitCubit>(() => LoadUnitCubit(repo));
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
}
