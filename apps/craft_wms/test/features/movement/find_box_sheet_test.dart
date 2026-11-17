import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:craft_wms/features/movement/presentation/widgets/find_box_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// P6-04: лист «Найти короб» - для испорченного ярлыка. Ищет по коду или адресу ячейки,
// показывает найденное разделами, касание выбирает короб. Ширина - настоящим Inter.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  const box = LoadUnitView(
    id: '00000000-0000-4000-8000-0000d35fae87',
    cellId: 'c1',
    cellAddress: 'M1-5-3-3',
    live: true,
    lines: [ContentLine(goodId: 'g', productionDate: '01-09-2026', qty: 12)],
  );

  /// Выбранный в листе короб - приходит, когда лист закрылся.
  LoadUnitView? picked;

  Future<void> open(WidgetTester tester, List<String> queries) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => picked = await showFindBoxSheet(
                  context,
                  search: (q) async {
                    queries.add(q);
                    return q == 'D35FAE87'
                        ? [
                            (t.movement.findBoxFound, [box]),
                          ]
                        : [(t.movement.findBoxFound, <LoadUnitView>[])];
                  },
                ),
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

  testWidgets(
    'ничего не найдено - так и сказано; найденное выбирается касанием',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final queries = <String>[];
      picked = null;
      await open(tester, queries);

      await tester.enterText(find.byType(TextField), 'FFFF');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text(t.movement.findBoxEmpty), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'D35FAE87');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('M1-5-3-3'), findsOneWidget);

      await tester.tap(find.textContaining('M1-5-3-3'));
      await tester.pumpAndSettle();
      expect(queries, containsAll(['FFFF', 'D35FAE87']));
      expect(picked?.id, box.id);
    },
  );
}
