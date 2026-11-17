import 'package:craft_wms/core/load_unit/load_unit_code.dart';
import 'package:craft_wms/core/load_unit/load_unit_id_generator.dart';
import 'package:craft_wms/core/scanner/scan_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

/// Генератор идентификаторов ГЕ (P4-04): короб получает свой номер на устройстве, без сети.
void main() {
  const generator = LoadUnitIdGenerator(Uuid());

  test('идентификаторы не повторяются', () {
    // Ярлык клеится на короб намертво: совпадение означало бы две ГЕ на один физический короб.
    final ids = List.generate(1000, (_) => generator.newId());
    expect(ids.toSet().length, ids.length);
  });

  test('выданный идентификатор - канонический UUID в нижнем регистре', () {
    final id = generator.newId();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')));
  });

  test('ярлык печатается в своём формате и читается обратно', () {
    final payload = generator.newLabelPayload();
    expect(payload, startsWith('CWLU1:'));
    expect(loadUnitIdFrom(payload), isNotNull);
  });

  test('свежий ярлык распознаётся сканером как грузовая единица', () {
    // Смысл задачи целиком: то, что мы печатаем, устройство обязано узнавать. Разъедься
    // генератор и разбор - терминал перестал бы понимать собственные наклейки.
    final payload = generator.newLabelPayload();
    expect(classifyScan(payload), ScanKind.cargoUnit);
    expect(ScanCode(raw: payload).loadUnitId, loadUnitIdFrom(payload));
  });
}
