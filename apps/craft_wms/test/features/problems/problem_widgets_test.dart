import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/problems/problem_reasons.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:craft_wms/core/widgets/neumorphic_choice.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/problems/presentation/bloc/problem_state.dart';
import 'package:craft_wms/features/problems/presentation/widgets/problem_choice.dart';
import 'package:craft_wms/features/problems/presentation/widgets/problem_form.dart';
import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// P6-07-2: выбор в источнике и форма «куда и почему» не переполняются на ширине ТСД. Ширины -
// настоящим Inter и темой приложения, как у карточки перемещения (тестовый шрифт шире вдвое).
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  const cell = Cell(id: 'c', warehouseId: 'w', address: 'M1-5-3-3');
  const line = ContentLine(
    goodId: 'g',
    goodName: 'Лимонад «Тархун» стекло 0,5 л, упаковка 12 шт',
    uom: 'шт',
    productionDate: '01-09-2026',
    qty: 12,
    internalWarehouseId: 'd',
    internalWarehouseName: 'Изолятор',
  );
  const box = LoadUnitView(
    id: '00000000-0000-4000-8000-0000d35fae87',
    cellId: 'c',
    live: true,
    lines: [line],
    internalWarehouseId: 'd',
    internalWarehouseName: 'Изолятор',
  );
  const warehouses = [
    InternalWarehouse(id: 'b', code: 'DEFECT', name: 'Брак', isDefault: false),
    InternalWarehouse(
      id: 'd',
      code: 'ISOLATOR',
      name: 'Изолятор',
      isDefault: false,
    ),
  ];

  Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: child),
      ),
    );
    expect(tester.takeException(), isNull, reason: 'переполнение на $width');
  }

  testWidgets('выбор в коробе и ячейке - без переполнения', (tester) async {
    for (final width in [320.0, 360.0]) {
      for (final source in const [
        ProblemSource.box(box: box, cell: cell),
        ProblemSource.cell(
          cell: cell,
          view: CellView(
            cellId: 'c',
            address: 'M1-5-3-3',
            loadUnits: [box],
            loose: [line],
          ),
        ),
      ]) {
        await pumpAt(
          tester,
          width,
          ProblemChoice(
            source: source,
            onWholeBox: () {},
            onBox: (_) {},
            onGoods: (_) {},
          ),
        );
      }
    }
    expect(
      find.text(t.problems.wholeBox),
      findsNothing,
      reason: 'последней была ячейка',
    );
  });

  testWidgets('форма «не наша марка» - все склады и причины, поле марки', (
    tester,
  ) async {
    for (final width in [320.0, 360.0]) {
      await pumpAt(
        tester,
        width,
        ProblemForm(
          state: ProblemState(
            subject: ProblemSubject.goods(
              line: line,
              qty: 2,
              cell: cell,
              box: box,
            ),
            reason: fallbackProblemReasons().firstWhere(
              (r) => r.code == ProblemReasonCodes.foreignMark,
            ),
          ),
          targets: warehouses,
          reasons: fallbackProblemReasons(),
          comment: TextEditingController(),
          mark: TextEditingController(),
          onWarehouse: (_) {},
          onTakePhoto: () {},
          onRemovePhoto: (_) {},
          onReason: (_) {},
        ),
      );
    }
    expect(find.text(t.problems.mark), findsOneWidget);
    // Варианты - неоморфные кнопки приложения, а не чипы Material; выбрана одна причина.
    // Причины - те, что переданы формой: справочник терминала (ADHOC-55).
    expect(
      find.byType(NeumorphicChoice),
      findsNWidgets(warehouses.length + fallbackProblemReasons().length),
    );
    expect(
      tester
          .widgetList<NeumorphicChoice>(find.byType(NeumorphicChoice))
          .where((c) => c.selected)
          .map((c) => c.label),
      [t.problems.reasonForeignMark],
    );
    expect(find.text(t.problems.qtyLine(qty: '2 шт')), findsOneWidget);
  });
}
