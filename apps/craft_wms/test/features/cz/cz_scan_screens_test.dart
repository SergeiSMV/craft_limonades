import 'dart:convert';
import 'dart:io';

import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/printer/load_unit_label.dart';
import 'package:craft_wms/features/cz/data/cz_scan_dto.dart';
import 'package:craft_wms/features/cz/domain/cz_scan.dart';
import 'package:craft_wms/features/cz/presentation/cz_scan_target.dart';
import 'package:craft_wms/features/cz/presentation/pages/cz_composition_page.dart';
import 'package:craft_wms/features/cz/presentation/widgets/cz_mark_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Эталон ответа скана с сервера — тот же, что в `cz_scan_http_test.go`.
Map<String, dynamic> _golden(String name) =>
    jsonDecode(
          File('../backend/internal/handler/testdata/$name').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// Скан «Честного знака» на ТСД (CZ-04): куда вести по ответу, блок марки, состав упаковки.
void main() {
  setUpAll(LocaleSettings.useDeviceLocale);

  group('czScanTarget', () {
    test('марка известного товара — карточка товара', () {
      final r = czScanFromJson(_golden('cz_scan_mark.json'));
      expect(czScanTarget(r), CzScanTarget.goodCard);
    });

    test('марка с незнакомым GTIN — привязка ШК, как у незнакомого ШК', () {
      final j = _golden('cz_scan_mark.json')
        ..['good'] = null
        ..['bind_barcode'] = '4612728200172';
      expect(czScanTarget(czScanFromJson(j)), CzScanTarget.bindBarcode);
    });

    test('марка без GTIN — товар не определить', () {
      final j = _golden('cz_scan_mark.json')..['good'] = null;
      expect(czScanTarget(czScanFromJson(j)), CzScanTarget.noGtin);
    });

    test('принятый короб — карточка ГЕ, непринятый — состав по ЧЗ', () {
      final j = _golden('cz_scan_box.json');
      expect(czScanTarget(czScanFromJson(j)), CzScanTarget.loadUnit);
      j.remove('load_unit_id');
      expect(czScanTarget(czScanFromJson(j)), CzScanTarget.composition);
    });

    test('групповая упаковка — состав по ЧЗ', () {
      final j = _golden('cz_scan_box.json')..['kind'] = 'GROUP';
      expect(czScanTarget(czScanFromJson(j)), CzScanTarget.composition);
    });
  });

  group('CzMarkSection', () {
    Future<void> pump(WidgetTester tester, CzScanResult r) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: CzMarkSection(scan: r)),
        ),
      ),
    );

    testWidgets('марка на складе: данные ЧЗ, короб, ячейка, приход', (
      tester,
    ) async {
      final r = czScanFromJson(_golden('cz_scan_mark.json'));
      await pump(tester, r);
      // Наименование по ЧЗ — своей строкой: с номенклатурой оно может не совпадать.
      expect(find.text(t.czScan.czNameLine(name: r.productName!)), findsOne);
      expect(find.text(t.czScan.czStatusLine(status: 'в обороте')), findsOne);
      expect(find.text(t.czScan.producedLine(date: '12.10.2026')), findsOne);
      expect(find.text(t.czScan.expiresLine(date: '10.04.2027')), findsOne);
      final box = LoadUnitLabel(r.mark!.loadUnitId!).shortCodeFormatted;
      expect(find.text(t.czScan.boxLine(code: box)), findsOne);
      expect(find.text(t.czScan.cellLine(address: 'M1-1-10-1')), findsOne);
      expect(find.text(t.czScan.notInWms), findsNothing);
    });

    testWidgets('марка не на складе — так и сказано', (tester) async {
      final j = _golden('cz_scan_mark.json')..['mark'] = null;
      await pump(tester, czScanFromJson(j));
      expect(find.text(t.czScan.notInWms), findsOne);
    });
  });

  group('CzCompositionPage', () {
    testWidgets('короб не принят: единицы, строка товар × партия', (
      tester,
    ) async {
      final j = _golden('cz_scan_box.json')..remove('load_unit_id');
      await tester.pumpWidget(
        MaterialApp(home: CzCompositionPage(scan: czScanFromJson(j))),
      );
      expect(find.text(t.czScan.boxTitle), findsOne);
      expect(find.text(t.czScan.unitsLine(count: 2)), findsOne);
      expect(find.text(t.czScan.notAccepted), findsOne);
      expect(find.text(t.czScan.unreadableLine(count: 1)), findsOne);
      expect(
        find.text(t.czScan.goodLine(name: 'Пиво «Голубые Гавайи», кега 30 л')),
        findsOne,
      );
      expect(find.text(t.czScan.batchLine(date: '12.10.2026')), findsOne);
      expect(find.text(t.czScan.qtyLine(count: 2)), findsOne);
    });
  });
}
