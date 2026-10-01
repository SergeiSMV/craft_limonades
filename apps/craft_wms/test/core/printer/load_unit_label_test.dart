import 'dart:convert';

import 'package:craft_wms/core/load_unit/load_unit_code.dart';
import 'package:craft_wms/core/printer/label_geometry.dart';
import 'package:craft_wms/core/printer/load_unit_label.dart';
import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// Коробочный ярлык ГЕ (P4-06): QR с идентификатором и короткий код для глаз.
void main() {
  const id = '550e8400-e29b-41d4-a716-446655440000';
  const label = LoadUnitLabel(id);
  const stock = LabelGeometry(widthMm: 58, heightMm: 40, gapMm: 2);

  String commands([LabelGeometry g = stock]) => latin1.decode(label.tspl(g));

  group('короткий код', () {
    test('это хвост идентификатора заглавными', () {
      // Хвост, а не начало: у UUID v4 случайна вся вторая половина.
      expect(label.shortCode, '55440000');
    });

    test('разбит пополам — чтобы человек не терял место', () {
      expect(label.shortCodeFormatted, '5544 0000');
    });

    test('короткий идентификатор не роняет построение', () {
      // Идентификатор приходит снаружи, и падать на нём ярлык не должен.
      expect(const LoadUnitLabel('abc').shortCode, 'ABC');
    });
  });

  group('набор кода человеком', () {
    test('пробел с ярлыка не мешает поиску', () {
      // Человек набирает код так, как видит его на наклейке. Поиск, не терпящий пробела,
      // превратил бы читаемую разбивку в ловушку.
      expect(LoadUnitLabel.normalizeShortCode('0F3E E350'), '0F3EE350');
      expect(LoadUnitLabel.normalizeShortCode('0F3EE350'), '0F3EE350');
    });

    test('регистр и дефис тоже прощаются', () {
      // Дефис появляется, если код переписали, подсмотрев форму UUID.
      expect(LoadUnitLabel.normalizeShortCode('0f3e-e350'), '0F3EE350');
      expect(LoadUnitLabel.normalizeShortCode(' 0f3e e350 '), '0F3EE350');
    });

    test('напечатанный код после нормализации совпадает с самим кодом', () {
      // Главная связка: то, что человек прочитал с ярлыка, обязано сойтись с тем,
      // что система знает о коробе.
      expect(
        LoadUnitLabel.normalizeShortCode(label.shortCodeFormatted),
        label.shortCode,
      );
    });
  });

  group('команды TSPL', () {
    test('в QR уезжает полезная нагрузка формата ярлыка, а не голый UUID', () {
      // Голый UUID приложение опознало бы как адрес ячейки — ровно то столкновение,
      // ради которого в P4-04 заведён префикс.
      expect(commands(), contains('"${encodeLoadUnitPayload(id)}"'));
      expect(commands(), contains('QRCODE '));
    });

    test('напечатанный QR сканер опознаёт как грузовую единицу', () {
      // Замыкание круга: то, что мы печатаем, терминал обязан узнавать. Разъедься шаблон
      // и разбор — склад клеил бы на короба коды, которые сам не читает.
      final payload = encodeLoadUnitPayload(id);
      expect(classifyScan(payload), ScanKind.cargoUnit);
      expect(ScanCode(raw: payload).loadUnitId, id);
    });

    test('короткий код печатается одной строкой внизу', () {
      final text = commands();
      expect(text, contains('"5544 0000"'));
      // Код прижат к низу: ближе к нижнему краю, чем к верхнему.
      final m = RegExp(r'TEXT \d+,(\d+),').firstMatch(text)!;
      final y = int.parse(m.group(1)!);
      expect(y, greaterThan(stock.heightDots ~/ 2));
    });

    test('QR выровнен по центру по ширине', () {
      final m = RegExp(r'QRCODE (\d+),').firstMatch(commands())!;
      final x = int.parse(m.group(1)!);
      final qrSide =
          LoadUnitLabel.qrModules(encodeLoadUnitPayload(id).length) * 8;
      expect(x, ((stock.widthDots - qrSide) / 2).round());
    });

    test('ширина QR считается по длине нагрузки, а не константой', () {
      // Иначе смена формата ярлыка увела бы QR из центра, и заметили бы это только на печати.
      expect(LoadUnitLabel.qrModules(42), 29);
      expect(LoadUnitLabel.qrModules(14), 21);
      expect(LoadUnitLabel.qrModules(50), 33);
    });

    test('кодовая страница объявлена до текста', () {
      // Ярлык ГЕ сейчас без русского, но страница задаётся всегда: иначе первый же
      // кириллический реквизит (P4-08) напечатался бы мусором, и причину искали бы долго.
      final text = commands();
      expect(text.indexOf('CODEPAGE 1251'), lessThan(text.indexOf('TEXT ')));
    });

    test('размер этикетки берётся из настроек', () {
      expect(commands(), contains('SIZE 58 mm,40 mm'));
      expect(
        commands(const LabelGeometry(widthMm: 40, heightMm: 30, gapMm: 3)),
        contains('SIZE 40 mm,30 mm'),
      );
    });

    test('раскладка не вылезает за край этикетки', () {
      // Отступ меньше 2 мм срезается подачей, а уехавший за край текст виден только
      // на печати — тестом дешевле.
      final text = commands();
      final xs = RegExp(r'TEXT (\d+),(\d+),').allMatches(text);
      expect(xs, isNotEmpty);
      for (final m in xs) {
        final x = int.parse(m.group(1)!);
        final y = int.parse(m.group(2)!);
        expect(x, greaterThanOrEqualTo(16));
        expect(x, lessThan(stock.widthDots));
        expect(y, greaterThanOrEqualTo(16));
        expect(y, lessThan(stock.heightDots));
      }
    });

    test('этикетка закрывается печатью одной штуки', () {
      // PRINT 1,1 — один набор, одна копия: повтор печати делает человек кнопкой,
      // а не количество в команде.
      expect(commands().trimRight(), endsWith('PRINT 1,1'));
    });

    test('повторная печать даёт те же команды', () {
      // «Повторно» — это тот же ярлык, а не новый: испорченную наклейку меняют на такую же.
      expect(label.tspl(stock), const LoadUnitLabel(id).tspl(stock));
    });
  });
}
