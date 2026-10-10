import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/documents_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/documents/doc_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ADHOC-25: строка документа перестраивается по своей ширине — на телефоне кнопки уходят под
// текст, на широкой области стоят слева от него. Ни там, ни там ничего не переполняется.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  final doc = PortalDoc(
    id: 'd1',
    kind: 'receipt',
    supplier: 'ИП ЛАПУШКИН СЕРГЕЙ АНДРЕЕВИЧ',
    docNumber: '4562655Н',
    docDate: '07-10-2026',
    warehouseCode: 'SHB',
    warehouseName: 'Шабулина',
    createdAt: DateTime(2026, 10, 9, 19, 5),
    linesCount: 1,
    status: DocStatus.isNew,
  );

  Future<void> pumpAt(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: DocRow(
                doc: doc,
                mark: 'Поступление',
                downloading: false,
                marking: false,
                onDownload: () {},
                onMarkDone: () {},
                onHistory: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('узкая строка (телефон): кнопки под текстом', (tester) async {
    await pumpAt(tester, 340);
    expect(tester.takeException(), isNull, reason: 'нет переполнения');
    final title = tester.getRect(find.textContaining('ЛАПУШКИН'));
    final download = tester.getRect(find.byIcon(Icons.download));
    expect(
      download.top,
      greaterThan(title.bottom),
      reason: 'кнопки ниже заголовка',
    );
    // Заголовок занимает почти всю ширину строки, а не узкую колонку.
    expect(title.width, greaterThan(300));
  });

  testWidgets('широкая строка: кнопки слева от текста', (tester) async {
    await pumpAt(tester, 800);
    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.textContaining('ЛАПУШКИН'));
    final download = tester.getRect(find.byIcon(Icons.download));
    expect(
      download.right,
      lessThan(title.left),
      reason: 'кнопки слева от текста',
    );
  });
}
