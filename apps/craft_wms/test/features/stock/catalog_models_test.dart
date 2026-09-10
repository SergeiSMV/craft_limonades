import 'package:craft_wms/features/stock/data/catalog_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StockItem · внутренний склад (ADR-0016)', () {
    test('разбирает учётную принадлежность', () {
      final item = StockItem.fromJson({
        'cell_id': 'c1',
        'cell_address': 'M1-1-1-1',
        'good_id': 'g1',
        'batch_id': 'b1',
        'production_date': '2026-08-14',
        'qty': '3.5',
        'internal_warehouse_id': 'w2',
        'internal_warehouse_name': 'Брак',
        'internal_warehouse_is_default': false,
      });
      expect(item.internalWarehouseName, 'Брак');
      expect(item.internalWarehouseIsDefault, isFalse);
      expect(item.qty, '3.5'); // decimal остаётся строкой — знаки не теряем
    });

    test('старый ответ без полей склада не роняет разбор', () {
      // Пока бэкенд не обновлён, строка приходит без новых полей. Считаем её основной:
      // пометка «брак» на обычном остатке пугала бы сильнее, чем её отсутствие.
      final item = StockItem.fromJson({
        'cell_id': 'c1',
        'cell_address': 'M1-1-1-1',
        'good_id': 'g1',
        'batch_id': 'b1',
        'production_date': '2026-08-14',
        'qty': '3.5',
      });
      expect(item.internalWarehouseName, isNull);
      expect(item.internalWarehouseIsDefault, isTrue);
    });
  });
}
