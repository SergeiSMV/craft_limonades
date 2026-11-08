import 'dart:convert';

import 'package:craft_wms/core/load_unit/load_unit_code.dart';
import 'package:craft_wms/core/printer/cp1251.dart';
import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:craft_wms/core/printer/picking_box_label.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ярлык короба отгрузки (P9-07): QR короба в формате ГЕ и шапка заказа.
void main() {
  const stock = LabelGeometry(widthMm: 58, heightMm: 40, gapMm: 2);
  const id = '3f2a8c1e-0b7d-4e5a-9c61-2d4f8a1b7e90';

  PickingBoxLabel label({List<String> body = const ['Клиент: ООО Ромашка']}) =>
      PickingBoxLabel(
        loadUnitId: id,
        title: 'СБ-000123',
        side: const ['Накладная: 20961', 'Заказ: 15512', '09.11.2026'],
        boxLine: 'Короб 2 из 3',
        body: body,
      );

  test('QR - ярлык ГЕ этого короба, печать одной этикетки', () {
    final cmd = latin1.decode(label().tspl(stock));
    expect(
      cmd,
      contains('QRCODE 16,16,M,5,A,0,"${encodeLoadUnitPayload(id)}"'),
    );
    expect(cmd, startsWith('SIZE 58 mm,40 mm'));
    expect(cmd, endsWith('PRINT 1,1\r\n'));
  });

  test('строки шапки и «Короб N из M» - в CP1251', () {
    final bytes = label().tspl(stock);
    for (final s in [
      'СБ-000123',
      'Накладная: 20961',
      'Короб 2 из 3',
      'Клиент: ООО Ромашка',
    ]) {
      expect(_contains(bytes, encodeCp1251(s)), isTrue, reason: s);
    }
  });

  test(
    'кавычка из реестра не обрывает команду, длинный адрес не вылезает за этикетку',
    () {
      final long = 'Адрес: ${'ул. Длинная, д. 1 "А", ' * 10}';
      final cmd = latin1.decode(label(body: [long]).tspl(stock));
      final texts = RegExp(r'TEXT \d+,(\d+),').allMatches(cmd).toList();
      // 5 строк справа от QR + не больше 4 строк под ним.
      expect(texts.length, lessThanOrEqualTo(9));
      for (final m in texts) {
        expect(int.parse(m.group(1)!), lessThan(stock.heightDots - 16));
      }
      expect(RegExp(r'"[^"\r\n]*"[^\r]*\r\n').hasMatch(cmd), isTrue);
      expect(
        cmd
            .split('\r\n')
            .where((l) => l.startsWith('TEXT'))
            .every((l) => '"'.allMatches(l).length == 4),
        isTrue,
      );
    },
  );
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
