import 'package:craft_wms/core/utils/keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Регрессия: при возврате на экран Flutter восстанавливает фокус последнему
/// сфокусированному полю — и экранная клавиатура всплывает сама. [dismissKeyboard],
/// вызванный перед переходом, должен это снимать.
void main() {
  /// Прогоняет сценарий «фокус в поле → переход на другой экран → возврат» и возвращает,
  /// остался ли фокус на поле после возврата.
  Future<bool> focusAfterReturn(
    WidgetTester tester, {
    required bool dismissBeforePush,
  }) async {
    final node = FocusNode(debugLabel: 'search');
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextField(focusNode: node),
                ElevatedButton(
                  onPressed: () {
                    if (dismissBeforePush) dismissKeyboard();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (inner) => Scaffold(
                          body: Center(
                            child: ElevatedButton(
                              onPressed: () => Navigator.of(inner).pop(),
                              child: const Text('назад'),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('открыть'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(
      node.hasFocus,
      isTrue,
      reason: 'тап по полю даёт фокус (и клавиатуру)',
    );

    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('назад'));
    await tester.pumpAndSettle();

    return node.hasFocus;
  }

  testWidgets('без dismissKeyboard фокус возвращается на поле (баг)', (
    tester,
  ) async {
    expect(await focusAfterReturn(tester, dismissBeforePush: false), isTrue);
  });

  testWidgets('dismissKeyboard перед переходом — на возврате поле без фокуса', (
    tester,
  ) async {
    expect(await focusAfterReturn(tester, dismissBeforePush: true), isFalse);
  });
}
