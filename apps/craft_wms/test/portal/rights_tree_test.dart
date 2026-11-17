import 'package:craft_wms/core/auth/rights.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/presentation/widgets/settings/rights_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADHOC-50: дерево прав с галочками в карточке должности. Галочка раздела ставит все его
/// действия и повторным нажатием снимает; часть отмечена - «полугалочка».
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  testWidgets('раздел отмечается и снимается целиком; часть - полугалочка', (
    tester,
  ) async {
    var selected = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => RightsTree(
                selected: selected,
                onChanged: (s) => setState(() => selected = s),
              ),
            ),
          ),
        ),
      ),
    );

    Checkbox boxOf(String label) => tester.widget<Checkbox>(
      find.descendant(
        of: find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first,
        matching: find.byType(Checkbox),
      ),
    );
    Future<void> tapBox(String label) async {
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(of: find.text(label), matching: find.byType(Row))
              .first,
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
    }

    final receipt = t.rights.receipt;
    await tapBox(receipt);
    expect(selected, {
      Rights.receiptView,
      Rights.receiptDownload,
      Rights.receiptPost,
    });
    expect(boxOf(receipt).value, isTrue);
    expect(
      boxOf(t.rights.portal).value,
      isNull,
      reason: 'портал отмечен частично',
    );

    await tapBox(receipt);
    expect(selected, isEmpty, reason: 'повторное нажатие снимает раздел');

    // Раскрыть раздел и отметить одно действие - у раздела полугалочка.
    await tester.tap(find.text(receipt));
    await tester.pumpAndSettle();
    await tapBox(t.rights.docPost);
    expect(selected, {Rights.receiptPost});
    expect(boxOf(receipt).value, isNull);
    await tapBox(t.rights.docPost);
    expect(selected, isEmpty, reason: 'действие снимается повторным нажатием');
  });

  test('сводка для строки должности - разделы по приложениям', () {
    expect(
      rightsSummary([
        Rights.receiptPost,
        Rights.problemsView,
        Rights.tsdMovement,
      ]),
      [
        '${t.rights.portal}: ${t.rights.receipt}, ${t.rights.problems}',
        '${t.rights.tsd}: ${t.rights.tsdMovement}',
      ],
    );
  });
}
