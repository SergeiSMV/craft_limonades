import 'dart:async';

import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/printer/printer_service.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/cz/domain/cz_scan.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock/domain/catalog_repository.dart';
import 'package:craft_wms/features/stock_entry/data/entry_draft_store.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:craft_wms/features/stock_entry/presentation/bloc/stock_entry_cubit.dart';
import 'package:craft_wms/features/stock_entry/presentation/widgets/cell_entry_view.dart';
import 'package:drift/native.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../support/fake_scanner_service.dart';

class _MockPrinter extends Mock implements PrinterService {}

class _MockEntryRepo extends Mock implements StockEntryRepository {}

class _MockCatalogRepo extends Mock implements CatalogRepository {}

const _gtin = '04612728200172';
const _unknownGtin = '04600000000017';
const _good = Good(id: 'g1', name: 'Пиво', uom: 'шт', czMarked: true);

String _mark(int i, {String gtin = _gtin}) => '01${gtin}21mark$i';

/// Сервер ЧЗ-подделка: пачки ждут, пока тест их отпустит.
class _CzRepo implements CzScanRepository {
  final calls = <List<String>>[];
  final gates = <Completer<void>>[];

  @override
  Future<Either<Failure, CzScanResult>> scan(String code) =>
      throw UnimplementedError();

  @override
  Future<Either<Failure, List<CzScanBatchItem>>> scanMany(
    List<String> codes,
  ) async {
    calls.add(codes);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return Right([
      for (final c in codes)
        CzScanBatchItem(requested: c, result: Right(_unit(c))),
    ]);
  }

  CzScanResult _unit(String code) {
    final gtin = code.substring(2, 16);
    return CzScanResult(
      code: code,
      kind: CzCodeKind.unit,
      gtin: gtin,
      productName: 'Пиво по ЧЗ',
      producedDate: DateTime(2026, 10, 12),
      good: gtin == _gtin ? const CzGood(id: 'g1', name: 'Пиво') : null,
      bindBarcode: gtin == _gtin ? null : gtin.substring(1),
    );
  }
}

/// «Ввод остатков»: марки ЧЗ сканируются подряд без ожидания ЧЗ (ADHOC-70).
void main() {
  const cell = Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1');

  late _MockCatalogRepo catalogRepo;
  late _CzRepo cz;
  late AppDatabase db;
  late StockEntryCubit cubit;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    catalogRepo = _MockCatalogRepo();
    cz = _CzRepo();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cubit = StockEntryCubit(
      _MockEntryRepo(),
      catalogRepo,
      EntryDraftStore(db),
      const LoadUnitIdGenerator(Uuid()),
      _MockPrinter(),
    );
    when(() => catalogRepo.goodById('g1')).thenAnswer((_) async => _good);
    for (final (type, value) in [
      (CatalogRepository, catalogRepo),
      (CzScanRepository, cz),
      (Talker, Talker()),
    ]) {
      if (type == CatalogRepository) {
        if (getIt.isRegistered<CatalogRepository>()) {
          getIt.unregister<CatalogRepository>();
        }
        getIt.registerSingleton<CatalogRepository>(value as CatalogRepository);
      } else if (type == CzScanRepository) {
        if (getIt.isRegistered<CzScanRepository>()) {
          getIt.unregister<CzScanRepository>();
        }
        getIt.registerSingleton<CzScanRepository>(value as CzScanRepository);
      } else if (!getIt.isRegistered<Talker>()) {
        getIt.registerSingleton<Talker>(value as Talker);
      }
    }
  });

  tearDown(() => cubit.close());

  Widget wrap() => MaterialApp(
    theme: buildAppTheme(),
    home: BlocProvider<StockEntryCubit>.value(
      value: cubit,
      child: Scaffold(
        body: BlocBuilder<StockEntryCubit, StockEntryState>(
          builder: (_, s) => CellEntryView(state: s),
        ),
      ),
    ),
  );

  int marksInCell() => cubit.state.lines.fold(0, (n, l) => n + l.marks.length);

  testWidgets('марки подряд: первая читается, остальные - следующей пачкой', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    cubit.selectCell(cell);
    await tester.pumpWidget(wrap());
    await tester.pump();

    scanner.emit(_mark(1));
    await tester.pump();
    for (final i in [2, 3, 4]) {
      scanner.emit(_mark(i));
      await tester.pump();
    }
    scanner.emit(
      _mark(3),
    ); // повтор, пока марка читается, - не читается второй раз
    await tester.pump();
    expect(cz.calls, [
      [_mark(1)],
    ]);
    expect(marksInCell(), 0);
    expect(cubit.czHold.busy, isTrue);

    cz.gates[0].complete();
    await tester.pump();
    await tester.pump();
    expect(cz.calls.last, [_mark(2), _mark(3), _mark(4)]);
    cz.gates[1].complete();
    await tester.pumpAndSettle();

    expect(marksInCell(), 4);
    expect(cubit.czHold.busy, isFalse);
    expect(find.text(t.stockEntry.czMarksAdded(count: 3)), findsOneWidget);
    await scanner.dispose();
  });

  testWidgets('скан под окном привязки ШК не теряется, окно - одно на GTIN', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    cubit.selectCell(cell);
    await tester.pumpWidget(wrap());
    await tester.pump();

    scanner.emit(_mark(1, gtin: _unknownGtin));
    await tester.pump();
    cz.gates[0].complete();
    await tester.pumpAndSettle();
    expect(find.text(t.czScan.bindPromptTitle), findsOneWidget);

    // Окно открыто: экран под ним не верхний, но марки ЧЗ берёт в очередь.
    scanner.emit(_mark(2, gtin: _unknownGtin));
    await tester.pump();
    expect(cz.calls.last, [_mark(2, gtin: _unknownGtin)]);
    scanner.emit(_mark(3));
    await tester.pump();
    cz.gates[1].complete();
    await tester.pump();
    await tester.pump();
    expect(cz.calls.last, [_mark(3)]);
    cz.gates[2].complete();
    await tester.pump();

    await tester.tap(find.text(t.stockListScreen.bindCancel));
    await tester.pumpAndSettle();

    // Отказ от привязки - на обе марки незнакомого товара, окно второй раз не открылось.
    expect(find.text(t.czScan.bindPromptTitle), findsNothing);
    expect(marksInCell(), 1);
    expect(cubit.state.lines.single.marks.single.cis, _mark(3));
    expect(cubit.czHold.busy, isFalse);
    await scanner.dispose();
  });
}
