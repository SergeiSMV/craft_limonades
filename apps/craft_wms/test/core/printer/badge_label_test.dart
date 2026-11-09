import 'dart:convert';

import 'package:craft_wms/core/printer/badge_label.dart';
import 'package:craft_wms/core/printer/cp1251.dart';
import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Бейдж сотрудника (ADHOC-65): ФИО, должность и Code128 из 16 цифр.
void main() {
  const stock = LabelGeometry(widthMm: 58, heightMm: 40, gapMm: 2);

  BadgeLabel label({String name = 'Иванов Иван Иванович'}) => BadgeLabel(
    number: '1000000023456781',
    fullName: name,
    position: 'Должность: Кладовщик',
  );

  test('штрихкод - Code128 с номером целиком, цифры под полосами', () {
    final cmd = latin1.decode(label().tspl(stock));
    expect(cmd, startsWith('SIZE 58 mm,40 mm'));
    expect(cmd, contains('"128",96,2,0,2,2,"1000000023456781"'));
    expect(cmd, endsWith('PRINT 1,1\r\n'));
  });

  test('ФИО и должность - в CP1251, кавычка - ёлочкой', () {
    final bytes = label(name: 'Петров "Пётр"').tspl(stock);
    for (final s in ['Петров «Пётр»', 'Должность: Кладовщик']) {
      expect(
        _contains(bytes, encodeCp1251(s)),
        isTrue,
        reason: 'нет строки «$s»',
      );
    }
  });

  test('длинное ФИО - не больше двух строк, штрихкод ниже текста', () {
    final l = label(
      name: 'Константинопольский-Добровольский Максимилиан Александрович',
    );
    expect(l.textLines(stock), hasLength(3)); // две строки ФИО + должность
    final cmd = latin1.decode(l.tspl(stock));
    final y = int.parse(
      RegExp(r'BARCODE 24,(\d+),').firstMatch(cmd)!.group(1)!,
    );
    expect(y, greaterThanOrEqualTo(24 + 3 * 24));
    expect(
      y + 96 + 30,
      lessThan(stock.heightMm * 8),
    ); // полосы и цифры влезают в 40 мм
  });
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
