import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/tasks/data/tasks_models.dart';
import 'package:craft_wms/features/tasks/presentation/widgets/detail/task_item_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Позиция задания (ADHOC-21): неоморфная плашка, касание открывает короб или товар —
/// в том числе уже размещённое.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  Future<int> tapCount(WidgetTester tester, TaskItem item) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TaskItemTile(item: item, onTap: () => taps++),
        ),
      ),
    );
    await tester.tap(find.byType(TaskItemTile));
    await tester.pumpAndSettle();
    return taps;
  }

  testWidgets('короб: код с ярлыка и состав, касание срабатывает', (
    tester,
  ) async {
    const item = TaskItem(
      lineNo: 1,
      loadUnitId: '5a0c1d2e-3f40-4b51-8c62-7d8e9fa0b1c2',
      contents: [
        TaskContent(
          good: TaskGood(id: 'g1', name: 'Кальмар', uom: 'шт'),
          productionDate: '01-09-2026',
          qty: '12',
        ),
      ],
    );

    expect(await tapCount(tester, item), 1);
    expect(find.text(t.tasks.box(code: '9FA0 B1C2')), findsOneWidget);
    expect(find.textContaining('Кальмар'), findsOneWidget);
  });

  testWidgets('россыпь, уже размещённая: приглушена, но открывается', (
    tester,
  ) async {
    const item = TaskItem(
      lineNo: 2,
      good: TaskGood(id: 'g1', name: 'Кальмар', uom: 'шт'),
      productionDate: '02-09-2026',
      qty: '3',
      remaining: '0',
      placed: true,
    );

    expect(await tapCount(tester, item), 1);
    expect(find.text(t.tasks.placed), findsOneWidget);
  });
}
