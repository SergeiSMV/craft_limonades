import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/core/widgets/qty_dialog.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/movement/domain/movement_models.dart';
import 'package:craft_wms/features/movement/presentation/widgets/move_goods_sheet.dart';
import 'package:craft_wms/features/movement/presentation/widgets/move_qty_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// P6-04, с DT50S: позиции «Что взять» - неоморфными плашками; диалог количества показывает,
// что берут - товар, партию и сколько её в источнике. Ширина - настоящим Inter, длинные
// наименования как в справочнике.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  const peanut = ContentLine(
    goodId: 'g1',
    goodName:
        'Арахис (Бобарахис) обжаренный соленый ПРЕМИУМ шт/1кг (ТМ Фома Лукич)',
    uom: 'шт',
    productionDate: '15-06-2026',
    qty: 10,
  );
  const sourCream = ContentLine(
    goodId: 'g2',
    goodName:
        'Арахис (Бобарахис) со вкусом "Сметана и лук" ПРЕМИУМ шт/1кг (ТМ Фома Лукич)',
    uom: 'шт',
    productionDate: '04-08-2026',
    qty: 10,
  );
  const box = MovePlace(
    cellId: 'c1',
    cellAddress: 'M1-5-3-3',
    loadUnitId: '00000000-0000-4000-8000-0000d35fae87',
  );

  Future<void> pumpWith(
    WidgetTester tester,
    double width,
    Future<void> Function(BuildContext) open,
  ) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('позиции - плашками без переполнения, касание выбирает', (
    tester,
  ) async {
    for (final width in [320.0, 360.0]) {
      (ContentLine, double)? picked;
      await pumpWith(tester, width, (context) async {
        picked = await showMoveGoodsSheet(context, const [
          (peanut, 10),
          (sourCream, 10),
        ]);
      });
      expect(tester.takeException(), isNull, reason: 'ширина $width');
      expect(find.text('10 шт'), findsNWidgets(2));

      await tester.tap(find.textContaining('Сметана и лук'));
      await tester.pumpAndSettle();
      expect(picked?.$1.goodId, 'g2');
    }
  });

  testWidgets('диалог количества показывает товар, партию и сколько в коробе', (
    tester,
  ) async {
    for (final width in [320.0, 360.0]) {
      await pumpWith(
        tester,
        width,
        (context) => showQtyDialog(
          context,
          max: 10,
          uom: 'шт',
          title: t.movement.qtyTitle,
          header: const MoveQtyHeader(line: peanut, available: 10, from: box),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'ширина $width');
      expect(find.text(t.movement.qtyTitle), findsOneWidget);
      // Во всю ширину с отступом 8 по бокам - как диалоги приёмки.
      // AlertDialog включает поля вокруг себя - мерим саму плашку диалога.
      final card = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.getSize(card).width, width - 16);
      expect(find.text(peanut.goodName!), findsOneWidget);
      expect(find.text('Партия 15.06.2026'), findsOneWidget);
      expect(find.text('В коробе D35F AE87: 10 шт'), findsOneWidget);

      await tester.tap(find.text(t.qtyDialog.cancel));
      await tester.pumpAndSettle();
    }
  });
}
