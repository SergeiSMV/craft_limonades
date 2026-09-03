import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/stock/presentation/widgets/stock_detail/bind_barcode_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_scanner_service.dart';

/// ADHOC-07: диалог привязки ШК не был подписан на поток сканера и в intent-режиме не получал
/// код вовсе — код уходит в поток, а поток доставляется только верхнему экрану стопки, тогда
/// как диалог экраном не является. Работал только клавиатурный режим, где код прилетает
/// в сфокусированное поле.
void main() {
  setUp(LocaleSettings.useDeviceLocale);

  /// Открыть диалог привязки; [onBind] отдаёт исход привязки.
  Future<List<String>> pump(WidgetTester tester, {Failure? failure}) async {
    final bound = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => BindBarcodeDialog(
                    onBind: (code) async {
                      bound.add(code);
                      return failure;
                    },
                  ),
                ),
                child: const Text('открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    return bound;
  }

  testWidgets('скан из потока привязывает код (регресс ADHOC-07)', (
    tester,
  ) async {
    final scanner = registerFakeScanner();
    final bound = await pump(tester);

    scanner.emit('4607044662964');
    await tester.pumpAndSettle();

    expect(bound, ['4607044662964']);
    expect(
      find.byType(BindBarcodeDialog),
      findsNothing,
      reason: 'успешная привязка закрывает диалог',
    );
    await scanner.dispose();
  });

  testWidgets('код виден в поле до отправки', (tester) async {
    final scanner = registerFakeScanner();
    await pump(tester, failure: const Failure.network());

    scanner.emit('4607044662964');
    await tester.pumpAndSettle();

    // Привязка не удалась — диалог остаётся, и в поле виден отсканированный код.
    expect(find.text('4607044662964'), findsOneWidget);
    expect(find.text(t.stockDetailScreen.bindFailed), findsOneWidget);
    await scanner.dispose();
  });

  // Режимы вывода сканера в настройках взаимоисключающие, но правит их человек, и
  // конфигурация «и то, и другое» дала бы две попытки привязки одного кода.
  testWidgets('дубль из двух источников привязывает один раз', (tester) async {
    final scanner = registerFakeScanner();
    final bound = await pump(tester, failure: const Failure.network());

    scanner.emit('4607044662964');
    await tester.pumpAndSettle();
    scanner.emit('4607044662964');
    await tester.pumpAndSettle();

    expect(bound, hasLength(1));
    await scanner.dispose();
  });

  // Адрес ячейки в поле привязки — порча справочника: код места хранения навсегда стал бы
  // штрихкодом товара. Тот же случай ловится во «Вводе остатков» (P2-01).
  testWidgets('адрес ячейки не привязывается, а объясняется', (tester) async {
    final scanner = registerFakeScanner();
    final bound = await pump(tester);

    scanner.emit('M1-1-10-1');
    await tester.pumpAndSettle();

    expect(bound, isEmpty);
    expect(find.text(t.stockDetailScreen.bindScannedCell), findsOneWidget);
    expect(find.byType(BindBarcodeDialog), findsOneWidget);
    await scanner.dispose();
  });

  testWidgets('ручной ввод с Enter по-прежнему привязывает', (tester) async {
    final scanner = registerFakeScanner();
    final bound = await pump(tester);

    await tester.enterText(find.byType(TextField), '4607044662964');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(bound, ['4607044662964']);
    await scanner.dispose();
  });
}
