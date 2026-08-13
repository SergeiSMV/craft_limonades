import 'package:craft_wms/features/stock_entry/presentation/date_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DateTextInputFormatter — авто-точки дд.мм.гггг', () {
    final f = DateTextInputFormatter();

    String format(String raw) => f
        .formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: raw, selection: TextSelection.collapsed(offset: raw.length)),
        )
        .text;

    test('цифры → расставляет точки после дня и месяца', () {
      expect(format('1'), '1');
      expect(format('15'), '15');
      expect(format('150'), '15.0');
      expect(format('1501'), '15.01');
      expect(format('15012'), '15.01.2');
      expect(format('15012026'), '15.01.2026');
    });

    test('нецифры отбрасываются, лишние цифры режутся до 8', () {
      expect(format('15.01.2026'), '15.01.2026'); // точки от повторного ввода — не двоятся
      expect(format('15a01b2026'), '15.01.2026');
      expect(format('150120261234'), '15.01.2026');
    });
  });

  group('isValidEntryDate', () {
    test('валидные', () {
      expect(isValidEntryDate('15.01.2026'), isTrue);
      expect(isValidEntryDate('29.02.2024'), isTrue); // високосный
    });
    test('невалидные', () {
      expect(isValidEntryDate('15-01-2026'), isFalse); // дефисы — не наш формат
      expect(isValidEntryDate('31.02.2026'), isFalse); // нет такого дня
      expect(isValidEntryDate('00.01.2026'), isFalse);
      expect(isValidEntryDate('15.13.2026'), isFalse);
      expect(isValidEntryDate('1.1.2026'), isFalse); // без ведущих нулей
      expect(isValidEntryDate(''), isFalse);
    });
  });
}
