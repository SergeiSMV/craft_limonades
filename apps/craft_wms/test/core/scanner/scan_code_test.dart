import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// Классификация скана: по ней экраны понимают, товар им отсканировали, ячейку или ГЕ.
void main() {
  group('classifyScan', () {
    test('сплошные цифры от 8 знаков — штрихкод товара', () {
      expect(classifyScan('4607091380001'), ScanKind.good); // EAN-13
      expect(classifyScan('20015467'), ScanKind.good); // EAN-8
      expect(classifyScan('12345678901234'), ScanKind.good); // ITF-14
    });

    test('адрес ячейки: сегменты через дефис, латиница и кириллица', () {
      expect(classifyScan('M1-1-10-1'), ScanKind.cell);
      expect(classifyScan('С-Н-П'), ScanKind.cell);
    });

    test('QR по имени символики — грузовая единица, что бы ни лежало в коде', () {
      expect(
        classifyScan('M1-1-10-1', symbology: 'QR_CODE'),
        ScanKind.cargoUnit,
      );
      expect(
        classifyScan('4607091380001', symbology: 'qr'),
        ScanKind.cargoUnit,
      );
      // Имя ровно в том виде, в каком его прислал декодер DT50S (снято живым сканом).
      expect(
        classifyScan('https://qr.domru.ru/domofon', symbology: 'QRCode'),
        ScanKind.cargoUnit,
      );
    });

    test('AIM важнее вендорского имени: `]Q0` — грузовая единица', () {
      // Буква схемы AIM стандартизована (ISO/IEC 15424) и не зависит от производителя сканера.
      expect(classifyScan('CU-000123', aim: ']Q0'), ScanKind.cargoUnit);
      // Пришёл AIM — имени уже не верим: оно вендорское и может расходиться с реальностью.
      expect(
        classifyScan('4607044660205', aim: ']C0', symbology: 'QRCode'),
        ScanKind.good,
      );
    });

    test('DataMatrix («Честный знак») за грузовую единицу не принимаем', () {
      // `]d2` — GS1 DataMatrix, носитель кодов маркировки. Он не QR, и правило ГЕ его не ловит;
      // разбор структуры GS1 появится, когда «Честный знак» войдёт в объём.
      expect(
        classifyScan('0104607044660205215Ab7', aim: ']d2'),
        // Реальный код маркировки: GTIN + серийный, есть буквы — по форме ни на что не похож,
        // и это правильный исход. Существенно, что он НЕ уходит в грузовую единицу.
        ScanKind.unknown,
      );
      expect(
        classifyScan('01046070446602052', aim: ']d2'),
        isNot(ScanKind.cargoUnit),
      );
    });

    test('Code128 с DT50S: ячейка и товар различаются формой кода', () {
      // Обе этикетки приходят одной символикой Code128 — решает форма полезной нагрузки.
      expect(classifyScan('M1-5-3-3', symbology: 'Code128'), ScanKind.cell);
      expect(
        classifyScan('4607044660205', symbology: 'Code128'),
        ScanKind.good,
      );
    });

    test(
      'числовой код символики не выдаётся за QR — таблица кодов не подтверждена',
      () {
        expect(classifyScan('4607091380001', symbology: '11'), ScanKind.good);
      },
    );

    test('короткие цифры и произвольный текст — не распознаны', () {
      expect(classifyScan('1234567'), ScanKind.unknown);
      expect(classifyScan('арахис'), ScanKind.unknown);
      expect(classifyScan('   '), ScanKind.unknown);
    });

    test('обрамляющие пробелы не мешают распознаванию', () {
      expect(classifyScan('  4607091380001 '), ScanKind.good);
    });
  });

  test('ScanCode отдаёт тип по своему коду и символике', () {
    const code = ScanCode(raw: 'M1-1-1-1');
    expect(code.kind, ScanKind.cell);
    expect(
      const ScanCode(raw: 'M1-1-1-1', symbology: 'QR').kind,
      ScanKind.cargoUnit,
    );
  });
}
