import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_filter.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ADHOC-26: панель поиска и фильтров не переполняется ни на какой ширине — на телефоне
// чипы переносятся. Ширины — настоящим Inter: тестовый шрифт шире почти вдвое.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  setUpAll(() async {
    final loader = FontLoader('Inter');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Inter/Inter-$w.otf'));
    }
    await loader.load();
  });

  testWidgets('панель без переполнения от телефона до монитора', (
    tester,
  ) async {
    for (final width in [320.0, 375.0, 398.0, 480.0, 700.0, 1100.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: DocToolbar(
                hint: t.portal.receipt.search,
                onQuery: (_) {},
                filter: DocFilter.all,
                counts: const {
                  DocFilter.all: 4,
                  DocFilter.waiting: 1,
                  DocFilter.posted: 3,
                },
                onFilter: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'ширина $width');
      expect(find.text(t.portal.documents.filterPosted), findsOneWidget);
    }
  });
}
