import 'package:craft_wms/core/load_unit/load_unit_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// Формат полезной нагрузки ярлыка ГЕ (P4-04): `CWLU<версия>:<uuid>`.
void main() {
  const id = '550e8400-e29b-41d4-a716-446655440000';

  group('encodeLoadUnitPayload', () {
    test('оборачивает идентификатор в схему с версией', () {
      expect(encodeLoadUnitPayload(id), 'CWLU1:$id');
    });

    test('UUID приводится к нижнему регистру и обрезается по краям', () {
      // Два написания одного идентификатора выглядели бы в отчётах как две разные ГЕ.
      expect(encodeLoadUnitPayload(id.toUpperCase()), 'CWLU1:$id');
      expect(encodeLoadUnitPayload('  $id  '), 'CWLU1:$id');
    });

    test('напечатанный ярлык читается обратно', () {
      expect(loadUnitIdFrom(encodeLoadUnitPayload(id)), id);
    });
  });

  group('readLoadUnitPayload', () {
    test('свой ярлык отдаёт чистый UUID, без префикса', () {
      // Префикс живёт только на этикетке: в load_units.id ему делать нечего, иначе смена
      // версии формата потребовала бы миграции данных.
      expect(readLoadUnitPayload('CWLU1:$id'), const LoadUnitPayloadId(id));
    });

    test('регистр схемы и UUID не важен', () {
      // Этикетку мог напечатать другой инструмент - требовать от него наш регистр не за что.
      expect(
        readLoadUnitPayload('cwlu1:${id.toUpperCase()}'),
        const LoadUnitPayloadId(id),
      );
    });

    test('незнакомая версия - отдельный случай, а не «чужой код»', () {
      // Кладовщик держит исправную этикетку; «код не распознан» отправил бы его искать
      // несуществующую поломку. Правильный ответ - обновить приложение.
      expect(
        readLoadUnitPayload('CWLU2:$id'),
        const LoadUnitPayloadUnsupported(2),
      );
      expect(loadUnitIdFrom('CWLU2:$id'), isNull);
    });

    test('чужие коды ярлыком ГЕ не читаются', () {
      for (final raw in [
        'https://qr.domru.ru/domofon', // тот самый QR с живой проверки DT50S
        '4607091380001', // штрихкод товара
        'M1-1-10-1', // адрес ячейки
        'С-Н-П', // дефолтная ячейка приёмки
        id, // голый UUID без префикса
        'CWLU1:не-уuid',
        'CWLU:$id', // без версии
        'CWLU1 $id', // без двоеточия
        'XCWLU1:$id', // префикс не с начала строки
        'CWLU1:$id-хвост',
        '',
      ]) {
        expect(
          readLoadUnitPayload(raw),
          const LoadUnitPayloadForeign(),
          reason: 'код "$raw" не должен читаться как ярлык ГЕ',
        );
      }
    });

    test('версия UUID не закрепляется', () {
      // Какую версию генерировать - дело генератора, а не читателя: пин на v4 сломал бы
      // переход, например, на v7, причём на уже наклеенных ярлыках.
      const v7 = '01912d68-783e-7000-a000-0123456789ab';
      expect(readLoadUnitPayload('CWLU1:$v7'), const LoadUnitPayloadId(v7));
    });

    test('обрамляющие пробелы не мешают разбору', () {
      expect(readLoadUnitPayload('  CWLU1:$id  '), const LoadUnitPayloadId(id));
    });
  });
}
