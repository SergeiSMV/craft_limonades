import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// Классификация скана: по ней экраны понимают, товар им отсканировали, ячейку или ГЕ.
///
/// ⚠ Правило изменилось в P4-04 (долг 7): решает СОДЕРЖИМОЕ кода, а не символика. Раньше любой
/// QR считался грузовой единицей, и на живой проверке DT50S ею оказалась ссылка на домофон.
void main() {
  const id = '550e8400-e29b-41d4-a716-446655440000';
  const label = 'CWLU1:$id';

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

    test('ярлык грузовой единицы — по формату полезной нагрузки', () {
      expect(classifyScan(label), ScanKind.cargoUnit);
      // Регистр схемы и UUID не важен: этикетку мог напечатать другой инструмент.
      expect(classifyScan('cwlu1:$id'), ScanKind.cargoUnit);
      expect(classifyScan('CWLU1:${id.toUpperCase()}'), ScanKind.cargoUnit);
    });

    test('чужой QR грузовой единицей НЕ считается', () {
      // Тот самый код с живой проверки DT50S: раньше приложение звало его грузовой единицей
      // только потому, что это QR. Символика больше не решает.
      expect(
        classifyScan('https://qr.domru.ru/domofon'),
        isNot(ScanKind.cargoUnit),
      );
      expect(classifyScan('https://qr.domru.ru/domofon'), ScanKind.unknown);
    });

    test('голый UUID за ярлык ГЕ не принимаем', () {
      // Без префикса UUID подходит под форму адреса ячейки (сегменты через дефис) — ровно то
      // столкновение, из-за которого признак принадлежности и вынесен в сами данные.
      expect(classifyScan(id), isNot(ScanKind.cargoUnit));
      expect(classifyScan(id), ScanKind.cell);
    });

    test('ярлык ГЕ незнакомой версии — не грузовая единица', () {
      // Прочесть такой ярлык приложение не может: что внутри новой версии, оно не знает.
      // Но и молчать об этом нельзя — см. тест readLoadUnitPayload ниже.
      expect(classifyScan('CWLU2:$id'), isNot(ScanKind.cargoUnit));
    });

    test('DataMatrix («Честный знак») за грузовую единицу не принимаем', () {
      // Код маркировки: GTIN + серийный, есть буквы — по форме ни на что не похож, и это
      // правильный исход. Существенно, что он НЕ уходит в грузовую единицу.
      expect(classifyScan('0104607044660205215Ab7'), ScanKind.unknown);
      expect(classifyScan('01046070446602052'), isNot(ScanKind.cargoUnit));
    });

    test('короткие цифры и произвольный текст — не распознаны', () {
      expect(classifyScan('1234567'), ScanKind.unknown);
      expect(classifyScan('арахис'), ScanKind.unknown);
      expect(classifyScan('   '), ScanKind.unknown);
    });

    test('обрамляющие пробелы не мешают распознаванию', () {
      expect(classifyScan('  4607091380001 '), ScanKind.good);
      expect(classifyScan('  $label '), ScanKind.cargoUnit);
    });
  });

  group('ScanCode', () {
    test('тип определяется кодом, а не символикой', () {
      expect(const ScanCode(raw: 'M1-1-1-1').kind, ScanKind.cell);
      // Символика приходит от драйвера и сохраняется для диагностики, но на тип не влияет:
      // QR-адрес ячейки остаётся ячейкой.
      expect(
        const ScanCode(raw: 'M1-1-1-1', symbology: 'QRCode').kind,
        ScanKind.cell,
      );
      expect(
        const ScanCode(raw: '4607044660205', aim: ']Q0').kind,
        ScanKind.good,
      );
    });

    test('ярлык ГЕ отдаёт чистый идентификатор', () {
      // На сервер уезжает UUID без префикса: префикс — свойство этикетки.
      expect(const ScanCode(raw: label).loadUnitId, id);
      expect(const ScanCode(raw: '4607044660205').loadUnitId, isNull);
    });
  });

  group('символика как подсказка', () {
    test('QR по имени распознаётся — для объяснения человеку', () {
      expect(isQrSymbology('QRCode'), isTrue);
      expect(isQrSymbology('qr_code'), isTrue);
      expect(isQrSymbology('Code128'), isFalse);
      expect(isQrSymbology(null), isFalse);
    });

    test('буква схемы AIM читается по стандарту', () {
      expect(aimScheme(']Q0'), 'Q');
      expect(aimScheme(']d2'), 'd');
      expect(aimScheme(']C0'), 'C');
      expect(aimScheme('Q0'), isNull);
      expect(aimScheme(null), isNull);
    });
  });
}
