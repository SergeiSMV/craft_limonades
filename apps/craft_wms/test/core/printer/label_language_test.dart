import 'dart:convert';

import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:craft_wms/core/printer/label_language.dart';
import 'package:flutter_test/flutter_test.dart';

/// Языки команд принтера этикеток (P4-05).
///
/// Проверяем форму команд, а не «что-нибудь непустое»: ошибка в одном символе управляющей
/// последовательности даёт принтер, который молча ничего не печатает, - отлаживать такое
/// на складе дороже, чем закрепить тестом здесь.
void main() {
  // Размер, отличный от умолчания: так видно, что команды берут его из настроек,
  // а не из зашитой константы - ровно та ошибка, из-за которой принтер выдавал лишнюю
  // пустую этикетку и мотал ленту.
  const geometry = LabelGeometry(widthMm: 58, heightMm: 30, gapMm: 3);

  group('TSPL', () {
    const language = TsplLanguage();
    late String commands;

    setUp(() => commands = latin1.decode(language.testLabel(geometry)));

    test('размер рулона берётся из настроек, а не зашит', () {
      expect(commands, contains('SIZE 58 mm,30 mm'));
      expect(commands, contains('GAP 3 mm,0 mm'));
    });

    test('калибровка объявляет размер и запускает измерение', () {
      // Размер перед GAPDETECT обязателен: измерение отталкивается от него, а не гадает с нуля.
      final calibration = latin1.decode(language.calibrate(geometry));
      expect(calibration, contains('SIZE 58 mm,30 mm'));
      expect(calibration.trimRight(), endsWith('GAPDETECT'));
    });

    test(
      'диагностика кириллицы объявляет кодовую страницу и перебирает шрифты',
      () {
        final probe = latin1.decode(language.cyrillicProbe(geometry));
        // Без CODEPAGE принтер трактует байты своей текущей страницей и печатает мусор.
        expect(probe, contains('CODEPAGE 1251'));
        // Каждый встроенный шрифт - отдельной строкой: одна этикетка отвечает на вопрос целиком.
        for (final font in ['1', '2', '3', '4', '5', '0']) {
          expect(probe, contains('"$font",0,1,1,'));
        }
      },
    );

    test('кириллица в диагностике уходит однобайтовой CP1251', () {
      // latin1-декодирование показывает сами байты: «А» обязана быть 0xC0, а не парой байтов.
      final probe = language.cyrillicProbe(geometry);
      expect(probe, containsAllInOrder([0xC0, 0xC1, 0xC2])); // АБВ
    });

    test('этикетка открывается размером и закрывается печатью', () {
      // Без SIZE принтер берёт размер из своих настроек и режет содержимое;
      // без PRINT этикетка остаётся в буфере и наружу не выходит.
      expect(commands, startsWith('SIZE '));
      expect(commands, contains('\nCLS\r\n'));
      expect(commands.trimRight(), endsWith('PRINT 1,1'));
    });

    test('команды разделены CRLF', () {
      // Принтеры этого класса ждут именно CRLF; одиночный LF часть прошивок игнорирует.
      expect(commands, isNot(contains(RegExp(r'[^\r]\n'))));
    });

    test('идентификатор и название заданы', () {
      expect(language.id, 'tspl');
      expect(language.title, 'TSPL');
    });
  });

  group('ZPL', () {
    const language = ZplLanguage();
    late String commands;

    setUp(() => commands = latin1.decode(language.testLabel(geometry)));

    test('этикетка обёрнута в ^XA … ^XZ', () {
      // Вне этой пары команды не образуют формат, и принтер их просто копит.
      expect(commands, startsWith('^XA'));
      expect(commands.trimRight(), endsWith('^XZ'));
    });

    test('миллиметры пересчитаны в точки при 203 dpi', () {
      // ZPL не понимает миллиметры. Ошибка в пересчёте даёт обрезанную этикетку, что на глаз
      // можно принять за неверный шаблон. 58 мм × 8 точек = 464, 30 мм × 8 = 240.
      expect(commands, contains('^PW464'));
      expect(commands, contains('^LL240'));
    });

    test('калибровка запускает измерение носителя', () {
      expect(latin1.decode(language.calibrate(geometry)).trim(), '~JC');
    });

    test('идентификатор и название заданы', () {
      expect(language.id, 'zpl');
      expect(language.title, 'ZPL');
    });
  });

  group('реестр языков', () {
    test('язык находится по идентификатору', () {
      expect(labelLanguageById('tspl'), isA<TsplLanguage>());
      expect(labelLanguageById('zpl'), isA<ZplLanguage>());
    });

    test('неизвестный или отсутствующий идентификатор - null', () {
      // Сохранённый выбор может указывать на язык, которого больше нет: сервис тогда
      // возьмёт язык по умолчанию, а не упадёт.
      expect(labelLanguageById('escpos'), isNull);
      expect(labelLanguageById(null), isNull);
    });

    test('все языки различимы по идентификатору', () {
      final ids = kLabelLanguages.map((l) => l.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  test('команды кодируются однобайтово', () {
    // latin1, а не UTF-8: команды состоят из ASCII, и многобайтовая кодировка дала бы
    // принтеру лишние байты там, где он ждёт один символ.
    expect(encodeCommands('^XA'), [0x5E, 0x58, 0x41]);
  });
}
