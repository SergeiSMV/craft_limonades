import 'package:craft_wms/core/utils/date_input.dart';
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

    test('двузначный год: 6 цифр → дд.мм.гг', () {
      expect(format('140826'), '14.08.26');
      expect(format('15.08.26'), '15.08.26');
    });
  });

  group('isValidEntryDate', () {
    test('валидные (4-значный год)', () {
      expect(isValidEntryDate('15.01.2026'), isTrue);
      expect(isValidEntryDate('29.02.2024'), isTrue); // високосный
    });
    test('валидные (2-значный год → 20YY)', () {
      expect(isValidEntryDate('15.01.26'), isTrue);
      expect(isValidEntryDate('29.02.24'), isTrue); // 2024 — високосный
    });
    test('невалидные', () {
      expect(isValidEntryDate('15-01-2026'), isFalse); // дефисы — не наш формат
      expect(isValidEntryDate('31.02.2026'), isFalse); // нет такого дня
      expect(isValidEntryDate('29.02.26'), isFalse); // 2026 не високосный
      expect(isValidEntryDate('00.01.2026'), isFalse);
      expect(isValidEntryDate('15.13.2026'), isFalse);
      expect(isValidEntryDate('1.1.2026'), isFalse); // без ведущих нулей
      expect(isValidEntryDate('15.01.202'), isFalse); // трёхзначный год
      expect(isValidEntryDate(''), isFalse);
    });
  });

  group('normalizeEntryDate', () {
    test('двузначный год приводится к 20YY', () {
      expect(normalizeEntryDate('14.08.26'), '14.08.2026');
      expect(normalizeEntryDate('01.01.30'), '01.01.2030');
    });
    test('четырёхзначный год не меняется', () {
      expect(normalizeEntryDate('14.08.2026'), '14.08.2026');
    });
  });

  group('isoToDisplayDate — ISO из API → дд.мм.гггг', () {
    test('дата и дата со временем', () {
      expect(isoToDisplayDate('2026-08-03'), '03.08.2026');
      expect(isoToDisplayDate('2026-08-10T00:00:00Z'), '10.08.2026');
    });

    test('неожиданный формат возвращается как есть', () {
      expect(isoToDisplayDate('03.08.2026'), '03.08.2026');
      expect(isoToDisplayDate(''), '');
    });
  });
}
