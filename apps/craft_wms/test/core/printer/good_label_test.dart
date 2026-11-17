import 'dart:convert';

import 'package:craft_wms/core/printer/good_label.dart';
import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:craft_wms/core/printer/label_language.dart';
import 'package:flutter_test/flutter_test.dart';

/// Товарный ярлык (P4-08): штрихкод и наименование.
void main() {
  const stock = LabelGeometry(widthMm: 58, heightMm: 40, gapMm: 2);

  String commands(GoodLabel label) => latin1.decode(label.tspl(stock));

  group('тип штрихкода выводится из формы кода', () {
    test('тринадцать цифр - EAN-13', () {
      // Символика из справочника необязательна (NULL, если неизвестна) и заполняется людьми,
      // а форма кода известна всегда.
      const label = GoodLabel(barcode: '2000000000015', goodName: 'Кальмар');
      expect(label.tsplType, 'EAN13');
      expect(commands(label), contains('"EAN13"'));
    });

    test('восемь цифр - EAN-8', () {
      expect(
        const GoodLabel(barcode: '20015467', goodName: 'Кальмар').tsplType,
        'EAN8',
      );
    });

    test('всё остальное - Code128', () {
      // Буквы, нестандартная длина, адрес ячейки - Code128 кодирует что угодно.
      for (final code in [
        'M1-1-10-1',
        '1234567890',
        'ABC123',
        '123456789012',
      ]) {
        expect(
          GoodLabel(barcode: code, goodName: 'Товар').tsplType,
          '128',
          reason: 'код $code',
        );
      }
    });
  });

  group('наименование', () {
    test('кириллица уходит однобайтовой CP1251', () {
      // Принтер при CODEPAGE 1251 ждёт один байт на символ; UTF-8 сместил бы весь текст.
      final bytes = const GoodLabel(
        barcode: '2000000000015',
        goodName: 'Кальмар',
      ).tspl(stock);
      expect(bytes, containsAllInOrder([0xCA, 0xE0, 0xEB])); // «Кал»
    });

    test('кавычки в наименовании заменяются ёлочками', () {
      // Найдено на живой печати: наименование «Арахис … со вкусом "Бекон" ПРЕМИУМ …»
      // закрывало команду TEXT на своей первой кавычке, принтер терял синхронизацию и
      // печатал только огрызок после последней кавычки - начало названия пропадало молча.
      // Экранирование \" прошивка игнорирует (тоже проверено печатью), поэтому символ
      // не экранируется, а заменяется.
      final text = commands(
        const GoodLabel(
          barcode: '4607044660205',
          goodName: 'Арахис со вкусом "Бекон" ПРЕМИУМ',
        ),
      );
      final content = RegExp(
        r'TEXT \d+,\d+,"2",0,1,1,"([^"]*)"',
      ).firstMatch(text)!.group(1)!;
      // Прямых кавычек внутри содержимого не остаётся вовсе - иначе команда закроется рано.
      expect(content, isNot(contains('"')));
    });

    test('прямые кавычки чередуются как открывающая и закрывающая', () {
      expect(
        sanitizeTsplText('со вкусом "Бекон" ПРЕМИУМ'),
        'со вкусом «Бекон» ПРЕМИУМ',
      );
      // Непарная кавычка считается открывающей - молча её терять нельзя.
      expect(sanitizeTsplText('25" диагональ'), '25« диагональ');
    });

    test('перевод строки в наименовании не обрывает команду', () {
      // В выгрузках 1С встречаются переносы; для TSPL они так же фатальны, как кавычка.
      expect(sanitizeTsplText('Арахис\nсолёный'), 'Арахис солёный');
    });

    test('кодовая страница объявлена до текста', () {
      final text = commands(
        const GoodLabel(barcode: '2000000000015', goodName: 'Кальмар'),
      );
      expect(text.indexOf('CODEPAGE 1251'), lessThan(text.indexOf('TEXT ')));
    });

    test('наименование в несколько строк печатается целиком', () {
      // 27 знаков на строку при шрифте «2»; четыре строки берут 108 - столько покрывает
      // наименования из 1С с фасовкой, сортом и торговой маркой.
      const fits =
          'Кальмар командорский очищенный замороженный в глазури ПРЕМИУМ '
          'шт/1кг (ТМ Фома Лукич)';
      final lines = const GoodLabel(
        barcode: '2000000000015',
        goodName: fits,
      ).nameLines(stock);
      expect(lines.length, greaterThan(1));
      expect(lines.join(' '), fits, reason: 'поместившееся не должно резаться');
      expect(lines.last, isNot(endsWith('…')));
    });

    test('длинное наименование переносится и обрезается многоточием', () {
      const long =
          'Кальмар командорский очищенный замороженный в глазури высшего сорта '
          'в потребительской упаковке по полтора килограмма нетто для розничной '
          'продажи и предприятий общественного питания';
      final lines = const GoodLabel(
        barcode: '2000000000015',
        goodName: long,
      ).nameLines(stock);

      expect(lines, hasLength(4), reason: 'печатаем не больше четырёх строк');
      // Обрезка видимая: молча потерянный хвост выглядел бы как другое наименование.
      expect(lines.last, endsWith('…'));
      // 27 знаков - (464 - 2*24) / 15 при измеренной ширине символа.
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(27));
      }
    });

    test('короткое наименование не трогается', () {
      final lines = const GoodLabel(
        barcode: '2000000000015',
        goodName: 'Кальмар',
      ).nameLines(stock);
      expect(lines, ['Кальмар']);
    });
  });

  group('wrapLabelText', () {
    test('переносит по словам, не разрывая их', () {
      expect(
        wrapLabelText(
          'Кальмар командорский очищенный',
          perLine: 12,
          maxLines: 3,
        ),
        ['Кальмар', 'командорский', 'очищенный'],
      );
    });

    test('слово длиннее строки рвётся жёстко', () {
      // Иначе наименование из одного длинного слова не влезло бы вовсе.
      expect(
        wrapLabelText('Полуфабрикатызамороженные', perLine: 10, maxLines: 3),
        ['Полуфабрик', 'атызаморож', 'енные'],
      );
    });

    test('лишние пробелы схлопываются', () {
      // В выгрузках 1С встречаются двойные пробелы и переносы.
      expect(wrapLabelText('  Кальмар   свежий  ', perLine: 20, maxLines: 2), [
        'Кальмар свежий',
      ]);
    });

    test('пустая строка даёт пустой список, а не строку из пробелов', () {
      expect(wrapLabelText('   ', perLine: 20, maxLines: 2), isEmpty);
    });
  });

  group('раскладка', () {
    test('EAN выравнивается по центру, Code128 - по левому краю', () {
      // Ширина EAN известна заранее (95 модулей), у Code128 зависит от содержимого -
      // центрировать его значило бы повторить промах с QR (ADHOC-17).
      final ean = RegExp(r'BARCODE (\d+),').firstMatch(
        commands(const GoodLabel(barcode: '2000000000015', goodName: 'Товар')),
      )!;
      expect(int.parse(ean.group(1)!), ((464 - 95 * 3) / 2).round());

      final code128 = RegExp(r'BARCODE (\d+),').firstMatch(
        commands(const GoodLabel(barcode: 'M1-1-10-1', goodName: 'Товар')),
      )!;
      expect(int.parse(code128.group(1)!), 24); // поле этикетки
    });

    test('штрихкод печатается ниже наименования', () {
      final text = commands(
        const GoodLabel(barcode: '2000000000015', goodName: 'Кальмар'),
      );
      final nameY = int.parse(
        RegExp(r'TEXT \d+,(\d+),').firstMatch(text)!.group(1)!,
      );
      final barcodeY = int.parse(
        RegExp(r'BARCODE \d+,(\d+),').firstMatch(text)!.group(1)!,
      );
      expect(barcodeY, greaterThan(nameY));
    });

    test('четыре строки наименования и штрихкод помещаются в высоту', () {
      // Самый плотный случай: имя занимает все отведённые строки. Если перестанет влезать,
      // это обязано упасть здесь, а не обнаружиться обрезанной наклейкой.
      final text = commands(
        const GoodLabel(
          barcode: '2000000000015',
          goodName:
              'Кальмар командорский очищенный замороженный в глазури высшего '
              'сорта в потребительской упаковке по полтора килограмма нетто',
        ),
      );
      expect(RegExp(r'TEXT ').allMatches(text), hasLength(4));
      final barcodeY = int.parse(
        RegExp(r'BARCODE \d+,(\d+),').firstMatch(text)!.group(1)!,
      );
      const barHeight = 120;
      const humanReadable = 28;
      expect(
        barcodeY + barHeight + humanReadable,
        lessThanOrEqualTo(stock.heightDots),
      );
    });

    test('всё помещается в высоту этикетки', () {
      // Полосы плюс цифры под ними: если не влезет, обнаружится обрезанной наклейкой.
      final text = commands(
        const GoodLabel(
          barcode: '2000000000015',
          goodName: 'Кальмар командорский очищенный замороженный',
        ),
      );
      final barcodeY = int.parse(
        RegExp(r'BARCODE \d+,(\d+),').firstMatch(text)!.group(1)!,
      );
      const barHeight = 120;
      const humanReadable = 28; // цифры под полосами печатает принтер
      expect(
        barcodeY + barHeight + humanReadable,
        lessThanOrEqualTo(stock.heightDots),
      );
    });

    test('этикетка закрывается печатью одной штуки', () {
      expect(
        commands(
          const GoodLabel(barcode: '2000000000015', goodName: 'Товар'),
        ).trimRight(),
        endsWith('PRINT 1,1'),
      );
    });

    test('перепечать даёт те же команды', () {
      // «Перепечать» - это тот же ярлык: испорченную наклейку меняют на такую же.
      const label = GoodLabel(barcode: '2000000000015', goodName: 'Товар');
      expect(
        label.tspl(stock),
        const GoodLabel(
          barcode: '2000000000015',
          goodName: 'Товар',
        ).tspl(stock),
      );
    });
  });
}
