import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:craft_wms/core/widgets/cell_change_sheet.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_scanner_service.dart';

class _MockRepo extends Mock implements CatalogRepository {}

/// ADHOC-07: нижний лист смены ячейки, как и диалог привязки, не был подписан на поток
/// сканера — в intent-режиме смена ячейки сканом молча не работала, только ручным вводом.
void main() {
  const cell = Cell(id: 'c2', warehouseId: 'w1', address: 'M1-1-10-1');
  late _MockRepo repo;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    repo = _MockRepo();
    when(
      () => repo.listAllCells(warehouseId: any(named: 'warehouseId')),
    ).thenAnswer((_) async => const Right([cell]));
    if (getIt.isRegistered<CatalogRepository>()) {
      getIt.unregister<CatalogRepository>();
    }
    getIt.registerSingleton<CatalogRepository>(repo);
  });

  /// Открыть лист; возвращает выбранные им ячейки.
  Future<List<Cell?>> pump(WidgetTester tester) async {
    final picked = <Cell?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final res = await showModalBottomSheet<Cell>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const CellChangeSheet(),
                  );
                  picked.add(res);
                },
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('скан адреса из потока выбирает ячейку (регресс ADHOC-07)', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    final picked = await pump(tester);

    scanner.emit('M1-1-10-1');
    await tester.pumpAndSettle();

    expect(picked, hasLength(1));
    expect(picked.single?.id, 'c2');
    await scanner.dispose();
  });

  testWidgets('неизвестный адрес не закрывает лист', (tester) async {
    final scanner = registerFakeScanner();
    final picked = await pump(tester);

    scanner.emit('M9-9-9-9');
    await tester.pumpAndSettle();

    expect(picked, isEmpty);
    expect(find.byType(CellChangeSheet), findsOneWidget);
    await scanner.dispose();
  });
}
