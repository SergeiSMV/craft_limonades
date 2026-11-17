import 'dart:typed_data';

import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/sync/data_versions.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/domain/cells/cells_repository.dart';
import 'package:craft_wms/portal/domain/cells/cell_setup.dart';
import 'package:craft_wms/portal/presentation/widgets/cells/label_preview.dart';
import 'package:craft_wms/portal/presentation/widgets/tabs/cells_tab.dart';
import 'package:craft_wms/portal/presentation/widgets/ui/portal_checkbox.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements CellsRepository {}

CellSetup cell(
  String id,
  String address,
  String? rack, {
  bool floor = false,
  bool small = false,
  bool card = false,
}) => CellSetup(
  id: id,
  address: address,
  rackId: rack,
  rackCode: rack == null ? null : 'B-0${rack.substring(1)}',
  isFloor: floor,
  labelSmall: small,
  labelBarcode: false,
  sideCard: card,
);

final setup = CellsSetup(
  warehouse: 'SHB',
  cells: [
    cell('c1', 'B-1-1-1', 'r1', floor: true, card: true),
    cell('c2', 'B-1-2-1', 'r1'),
    cell('c3', 'B-2-1-1', 'r2', small: true),
    cell('c4', 'Z-9', null),
  ],
  racks: const [
    Rack(id: 'r1', code: 'B-01'),
    Rack(id: 'r2', code: 'B-02'),
  ],
);

/// ADHOC-57: страница «Ячейки» - список, карточка ячейки, массовая отметка, права, печать.
void main() {
  late _MockRepo repo;
  final saved = <String>[];

  setUpAll(() {
    registerFallbackValue(LabelKind.large);
    registerFallbackValue(<CellFlag, bool>{});
  });

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    // ADHOC-60: вкладки слушают версии данных сервера.
    if (!getIt.isRegistered<DataVersions>()) {
      getIt.registerSingleton(DataVersions());
    }
    saved.clear();
    repo = _MockRepo();
    getIt.registerSingleton<CellsRepository>(repo);
    when(repo.loadSetup).thenAnswer((_) async => Right(setup));
    when(
      () => repo.saveSettings(any(), any()),
    ).thenAnswer((_) async => const Right(1));
  });

  tearDown(getIt.reset);

  Future<void> pump(
    WidgetTester tester, {
    double width = 1400,
    bool canEdit = true,
    bool canImport = true,
    bool canLabels = true,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CellsTab(
            canImport: canImport,
            canLabels: canLabels,
            canEdit: canEdit,
            save:
                ({
                  required Uint8List bytes,
                  required String filename,
                  String mime = '',
                }) => saved.add(filename),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final s = t.portal.cells;

  testWidgets(
    'широко - колонки и карточка справа; строка открывает образец этикетки',
    (tester) async {
      await pump(tester);

      expect(find.text(s.colTier), findsOneWidget);
      expect(find.text(s.side.placeholderTitle), findsOneWidget);
      expect(find.text(s.shown(shown: 4, total: 4)), findsOneWidget);

      await tester.tap(find.text('B-1-1-1'));
      await tester.pumpAndSettle();

      expect(
        find.text('B-1-1-1'),
        findsNWidgets(2),
      ); // строка и заголовок карточки
      expect(find.byType(LabelPreview), findsOneWidget);
      expect(find.text(s.side.sideCardHint), findsOneWidget);
    },
  );

  testWidgets('галочка карточки → «Сохранить» шлёт только её', (tester) async {
    await pump(tester);
    await tester.tap(find.text('B-1-2-1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(s.side.small));
    await tester.pumpAndSettle();
    expect(find.text(s.side.dirty), findsOneWidget);
    expect(find.text(s.side.sizeSmall(height: '46,2')), findsOneWidget);

    await tester.ensureVisible(find.text(s.side.save));
    await tester.tap(find.text(s.side.save));
    await tester.pumpAndSettle();

    verify(() => repo.saveSettings(['c2'], {CellFlag.small: true})).called(1);
    verify(repo.loadSetup).called(2);
    expect(find.text(s.side.saved(cells: 1)), findsOneWidget);
  });

  testWidgets('ярлык «Карточка» - по галочке ячейки', (tester) async {
    await pump(tester);

    expect(find.text(s.badgeCard), findsOneWidget); // только c1
  });

  testWidgets('«Карточка на стойку» у ячейки без стеллажа недоступна', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Z-9'));
    await tester.pumpAndSettle();

    expect(find.text(s.side.sideCardNoRack), findsOneWidget);
    final row = find.widgetWithText(InkWell, s.side.sideCard);
    expect(tester.widget<InkWell>(row).onTap, isNull);
    final box = tester.widget<PortalCheckbox>(
      find.descendant(of: row, matching: find.byType(PortalCheckbox)),
    );
    expect(box.value, isFalse);
  });

  testWidgets('«Карточка на стойку» - флаг ячейки в PATCH', (tester) async {
    await pump(tester);
    await tester.tap(find.text('B-1-2-1'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InkWell, s.side.sideCard));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(s.side.save));
    await tester.tap(find.text(s.side.save));
    await tester.pumpAndSettle();

    verify(
      () => repo.saveSettings(['c2'], {CellFlag.sideCard: true}),
    ).called(1);
  });

  testWidgets(
    '«отметить все» берёт все ячейки под фильтр, не только показанные',
    (tester) async {
      // Ячеек больше страницы списка: показаны первые 50 из 120.
      final many = CellsSetup(
        warehouse: 'SHB',
        cells: [for (var i = 1; i <= 120; i++) cell('m$i', 'B-1-1-$i', 'r1')],
        racks: const [Rack(id: 'r1', code: 'B-01')],
      );
      when(repo.loadSetup).thenAnswer((_) async => Right(many));
      await pump(tester);

      await tester.tap(find.byType(PortalCheckbox).first);
      await tester.pumpAndSettle();
      expect(find.text(s.side.pickedTitle(count: 120)), findsOneWidget);
      expect(
        tester.widget<PortalCheckbox>(find.byType(PortalCheckbox).first).value,
        isTrue,
      );

      await tester.tap(find.byType(PortalCheckbox).first);
      await tester.pumpAndSettle();
      expect(find.text(s.side.pickedTitle(count: 120)), findsNothing);
    },
  );

  testWidgets('отметка нескольких: черта у части, нажатие ставит всем', (
    tester,
  ) async {
    await pump(tester);
    final boxes = find.byType(PortalCheckbox);
    // 0 - «отметить все», дальше строки в порядке наклейки: c2 (ярус 2 выше), c1, c3.
    await tester.tap(boxes.at(2));
    await tester.tap(boxes.at(3));
    await tester.pumpAndSettle();

    expect(find.text(s.side.pickedTitle(count: 2)), findsOneWidget);
    expect(find.text(s.unpick(count: 2)), findsOneWidget);
    final floor = find.widgetWithText(InkWell, s.side.floor);
    final box = tester.widget<PortalCheckbox>(
      find.descendant(of: floor, matching: find.byType(PortalCheckbox)),
    );
    expect(box.value, isNull);

    await tester.tap(floor);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(s.side.save));
    await tester.tap(find.text(s.side.save));
    await tester.pumpAndSettle();

    verify(
      () => repo.saveSettings(['c1', 'c3'], {CellFlag.floor: true}),
    ).called(1);
  });

  testWidgets(
    'без прав - галочки только для просмотра, нет загрузки и печати',
    (tester) async {
      await pump(tester, canEdit: false, canImport: false, canLabels: false);
      await tester.tap(find.text('B-1-1-1'));
      await tester.pumpAndSettle();

      expect(find.text(s.side.readOnly), findsOneWidget);
      expect(find.text(s.side.save), findsNothing);
      expect(find.text(s.import), findsNothing);
      expect(find.text(s.print), findsNothing);
      expect(find.text(s.export), findsOneWidget);
    },
  );

  testWidgets('узко - без карточки справа, строка открывает окно', (
    tester,
  ) async {
    await pump(tester, width: 560);

    expect(find.text(s.side.placeholderTitle), findsNothing);
    expect(find.text(s.colTier), findsNothing);
    expect(find.text(s.rackLine(value: 'B-01')), findsNWidgets(2));

    await tester.tap(find.text('B-2-1-1'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(LabelPreview), findsOneWidget);
  });

  testWidgets('печать: PDF по видам; отказ 422 - текстом в окне', (
    tester,
  ) async {
    when(() => repo.labelsPdf(any(), any())).thenAnswer((inv) async {
      final kind = inv.positionalArguments.first as LabelKind;
      return kind == LabelKind.cards
          ? const Left(Failure.server(422, 'адрес не влезает'))
          : Right(Uint8List(1));
    });
    await pump(tester);

    await tester.tap(find.text(s.print));
    await tester.pumpAndSettle();
    expect(
      find.text(t.portal.cells.printDialog.count(count: 3)),
      findsOneWidget,
    ); // большая балка
    await tester.tap(find.text(t.portal.cells.printDialog.download));
    await tester.pumpAndSettle();

    verify(() => repo.labelsPdf(LabelKind.large, const [])).called(1);
    verify(() => repo.labelsPdf(LabelKind.small, const [])).called(1);
    expect(saved, ['labels_large.pdf', 'labels_small.pdf']);
    expect(
      find.text(
        t.portal.cells.printDialog.failed(
          kind: t.portal.cells.printDialog.cards,
          message: 'адрес не влезает',
        ),
      ),
      findsOneWidget,
    );
  });
}
