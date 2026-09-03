import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/features/home/presentation/widgets/sync_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADHOC-10: до индикатора обновление справочников ничем себя не выдавало — кладовщик видел
/// короткий снэкбар «обновляю» и дальше не знал, идёт ли что-то и стоит ли ждать.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  Future<ValueNotifier<bool>> pump(WidgetTester tester, bool running) async {
    final state = ValueNotifier(running);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncIndicator(running: state)),
      ),
    );
    return state;
  }

  testWidgets('в покое индикатора нет', (tester) async {
    await pump(tester, false);

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('во время обновления индикатор виден', (tester) async {
    await pump(tester, true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byTooltip(t.homeScreen.syncInProgressHint),
      findsOneWidget,
      reason: 'кружок без подписи не объясняет, чего ждать',
    );
  });

  // Состояние приходит из службы, поэтому индикатор обязан реагировать на его смену, а не
  // только на своё построение: обновление стартует автоматически после входа, то есть ровно
  // когда главное меню появляется на экране.
  testWidgets('индикатор следит за состоянием, а не за построением', (
    tester,
  ) async {
    final state = await pump(tester, false);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    state.value = true;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    state.value = false;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
