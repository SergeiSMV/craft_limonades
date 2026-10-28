import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/problems_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/problems/problem_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _cis = '0104660326900093215abcdefghijkl';

/// «Не наша марка» товаром с привязанной маркой и старой текстовой.
PortalProblem _problem() => PortalProblem(
  id: 'p1',
  createdAt: DateTime.utc(2026, 10, 28, 7, 14),
  createdBy: 'Администратор',
  cellAddress: 'С-1-1-1',
  loadUnitId: '',
  reason: 'foreign_mark',
  comment: 'не вернули',
  mark: 'старая-марка',
  fromWarehouse: 'Основной',
  toWarehouse: 'Изолятор',
  items: const [
    PortalProblemItem(
      goodCode: '00-1',
      goodName: 'Чипсы',
      productionDate: '2026-10-14',
      qty: 1,
      cellAddress: 'С-1-1-1',
    ),
  ],
  decisions: const [],
  suggestedSupplierId: '',
  resolved: false,
  decision: '',
  docNumber: '',
  docDate: '',
  supplierName: '',
  returnTaskNumber: 0,
  resolvedBy: '',
  resolvedAt: null,
  marks: const [_cis],
);

/// ADHOC-52: карточка проблемы — ячейка только в строке товара, подписанные склад и
/// комментарий, марки ЧЗ с копированием.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  testWidgets('подписи, марки и копирование марки', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProblemCard(problem: _problem(), busy: false),
          ),
        ),
      ),
    );

    expect(find.text('Ячейка С-1-1-1'), findsNothing);
    expect(
      find.text(t.portal.problems.itemCell(cell: 'С-1-1-1')),
      findsOneWidget,
    );
    expect(
      find.text(t.portal.problems.warehouses(from: 'Основной', to: 'Изолятор')),
      findsOneWidget,
    );
    expect(
      find.text(t.portal.problems.comment(text: 'не вернули')),
      findsOneWidget,
    );
    expect(find.text(t.portal.problems.marksTitle), findsOneWidget);
    expect(find.text(_cis), findsOneWidget);
    // Текстовая марка при привязанных не показывается: у короба ЧЗ там код короба.
    expect(find.text('старая-марка'), findsNothing);

    await tester.tap(find.byTooltip(t.portal.problems.markCopy).first);
    await tester.pump();
    expect(copied, _cis);
    expect(find.text(t.portal.problems.markCopied), findsOneWidget);
  });
}
