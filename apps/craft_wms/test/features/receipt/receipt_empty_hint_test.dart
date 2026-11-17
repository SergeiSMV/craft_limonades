import 'package:craft_wms/features/receipt/presentation/widgets/receipt_scan_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Подсказка пустой приёмки под открытой клавиатурой (ADHOC-18).
///
/// На DT50S рабочий экран сжался под клавиатурой, оставшейся от поиска поставщика, и колонка
/// «картинка + текст» переполнилась на 37 точек. Здесь над клавиатурой остаётся 70 точек на
/// подсказку - меньше её высоты (~160): она обязана прокручиваться, а не переполняться.
void main() {
  testWidgets('подсказка в узкой полосе прокручивается без переполнения', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    // 720 − клавиатура 450 − шапка 200 = 70 точек на подсказку.
    tester.view.viewInsets = const FakeViewPadding(bottom: 450);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 200), // шапка приёмки и поле скана
              Expanded(child: ReceiptEmptyHint()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
