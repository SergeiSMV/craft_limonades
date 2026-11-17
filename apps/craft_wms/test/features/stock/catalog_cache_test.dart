import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/features/stock/data/catalog_cache.dart';
import 'package:craft_wms/features/stock/domain/catalog_models.dart';
import 'package:craft_wms/features/stock/domain/group_tree.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Кэш справочников: локальный поиск должен давать тот же результат, что серверный (P-FS-17),
/// иначе кладовщик увидит разные списки в сети и без неё.
void main() {
  late AppDatabase db;
  late CatalogCache cache;

  const goods = [
    Good(
      id: 'g1',
      code: '15567',
      name: 'Арахис в хрустящей корочке Бекон',
      fullName: 'Арахис в хрустящей корочке Бекон (ТМ Фома Лукич)',
      uom: 'шт',
      groupId: 'grp-snacks',
      supplierId: 'sup-1',
    ),
    Good(
      id: 'g2',
      code: '14385',
      name: 'Шоколадная плитка горькая',
      uom: 'шт',
      groupId: 'grp-choco',
      supplierId: 'sup-2',
    ),
    Good(id: 'g3', code: '99001', name: 'Мёд гречишный', uom: 'кг'),
  ];

  const groups = [
    NomenclatureGroup(id: 'grp-food', code: '1', name: 'Продукты'),
    NomenclatureGroup(
      id: 'grp-snacks',
      code: '1.1',
      name: 'Снеки',
      parentId: 'grp-food',
    ),
    NomenclatureGroup(
      id: 'grp-choco',
      code: '1.2',
      name: 'Шоколад',
      parentId: 'grp-food',
    ),
  ];

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CatalogCache(db);
    await cache.putGoods(goods);
    await cache.putGroups(groups);
  });

  tearDown(() => db.close());

  group('поиск товаров', () {
    test('все слова присутствуют, порядок не важен', () async {
      // Ровно тот случай, ради которого в P-FS-17 переделывали серверный поиск.
      final page = await cache.searchGoods(query: 'фома бекон');
      expect(page.items.map((g) => g.id), ['g1']);
    });

    test('ищет и по коду, и по полному названию', () async {
      expect((await cache.searchGoods(query: '15567')).items.length, 1);
      expect((await cache.searchGoods(query: 'лукич')).items.length, 1);
    });

    test('регистр и «ё» не мешают', () async {
      expect((await cache.searchGoods(query: 'АРАХИС')).items.length, 1);
      expect((await cache.searchGoods(query: 'мед')).items.length, 1);
      expect((await cache.searchGoods(query: 'мёд')).items.length, 1);
    });

    test('спецсимволы LIKE не превращают запрос в шаблон', () async {
      // Без экранирования «%» нашёл бы вообще всё.
      expect((await cache.searchGoods(query: '%')).items, isEmpty);
      expect((await cache.searchGoods(query: '_')).items, isEmpty);
    });

    test('пустой запрос отдаёт весь справочник', () async {
      final page = await cache.searchGoods();
      expect(page.total, 3);
    });

    test('пагинация: total по всей выборке, items - по странице', () async {
      final page = await cache.searchGoods(limit: 2, offset: 0);
      expect(page.items.length, 2);
      expect(page.total, 3);

      final second = await cache.searchGoods(limit: 2, offset: 2);
      expect(second.items.length, 1);
      expect(second.total, 3);
    });
  });

  group('фильтры', () {
    test('фильтр по группе работает по поддереву', () async {
      // Выбор родительской группы должен показывать товары вложенных, иначе он даёт пусто.
      final ids = descendantGroupIds(groups, 'grp-food');
      final page = await cache.searchGoods(groupIds: ids);
      expect(page.items.map((g) => g.id), containsAll(['g1', 'g2']));

      final leaf = await cache.searchGoods(
        groupIds: descendantGroupIds(groups, 'grp-snacks'),
      );
      expect(leaf.items.map((g) => g.id), ['g1']);
    });

    test('фильтр по поставщику', () async {
      final page = await cache.searchGoods(supplierId: 'sup-2');
      expect(page.items.map((g) => g.id), ['g2']);
    });

    test('поиск и фильтр складываются', () async {
      final page = await cache.searchGoods(
        query: 'арахис',
        supplierId: 'sup-2',
      );
      expect(page.items, isEmpty);
    });
  });

  group('запись справочника', () {
    test('повторная укладка ЗАМЕНЯЕТ содержимое, а не дополняет', () async {
      // Сервер отдаёт справочник целиком; при слиянии удалённые записи жили бы в кэше вечно.
      await cache.putGoods(const [
        Good(id: 'g9', name: 'Единственный', uom: 'шт'),
      ]);
      final page = await cache.searchGoods();
      expect(page.total, 1);
      expect(page.items.single.id, 'g9');
    });

    test('отметка о синхронизации ставится при укладке', () async {
      expect(await cache.syncedAt(CatalogName.goods), isNotNull);
      expect(await cache.syncedAt(CatalogName.cells), isNull);
    });

    test('готовность считается по каждому справочнику отдельно', () async {
      // Не «всё или ничего»: один недоступный справочник не должен отключать офлайн
      // для остальных. Товары и группы уже уложены в setUp.
      expect(await cache.has(CatalogName.goods), isTrue);
      expect(await cache.has(CatalogName.groups), isTrue);
      expect(await cache.has(CatalogName.cells), isFalse);
      expect(await cache.has(CatalogName.barcodes), isFalse);

      await cache.putCells(const [
        Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1'),
      ]);
      expect(await cache.has(CatalogName.cells), isTrue);
      expect(await cache.has(CatalogName.barcodes), isFalse);
    });

    test('пустой справочник тоже считается загруженным', () async {
      // Иначе склад без единой привязки ШК навсегда остался бы «несинхронизированным»
      // и каждый скан уходил бы в сеть.
      await cache.putBarcodes([]);
      expect(await cache.has(CatalogName.barcodes), isTrue);
    });
  });

  group('ячейки', () {
    setUp(() async {
      await cache.putCells(const [
        Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1'),
        Cell(id: 'c2', warehouseId: 'w1', address: 'M1-5-3-3', isFloor: true),
        Cell(id: 'c3', warehouseId: 'w2', address: 'K2-1-1-1'),
      ]);
    });

    test('поиск по адресу регистронезависим', () async {
      expect((await cache.cells(query: 'm1-5')).single.id, 'c2');
      expect((await cache.cells(query: 'M1-5')).single.id, 'c2');
    });

    test('фильтры по складу и напольности', () async {
      expect((await cache.cells(warehouseId: 'w1')).length, 2);
      expect((await cache.cells(isFloor: true)).single.id, 'c2');
    });

    // Приёмка находит по флагу склад и ячейку по умолчанию без связи (P4-09).
    test('флаг дефолтной ячейки переживает укладку в кэш', () async {
      await cache.putCells(const [
        Cell(id: 'c1', warehouseId: 'w1', address: 'M1-1-1-1'),
        Cell(id: 'cd', warehouseId: 'w1', address: 'С-Н-П', isDefault: true),
      ]);
      final cells = await cache.cells();
      expect(cells.where((c) => c.isDefault).single.id, 'cd');
      expect(cells.firstWhere((c) => c.id == 'c1').isDefault, isFalse);
    });

    test('без фильтров отдаёт весь справочник', () async {
      expect((await cache.cells()).length, 3);
    });
  });

  group('штрихкоды', () {
    test('резолв товара по ШК', () async {
      await cache.putBarcodes([
        (barcode: '4607044660205', goodId: 'g1', symbology: 'Code128'),
      ]);
      expect((await cache.goodByBarcode('4607044660205'))?.id, 'g1');
      expect(await cache.goodByBarcode('0000000000000'), isNull);
    });

    test('точечная привязка и отвязка не трогают остальные', () async {
      await cache.putBarcodes([
        (barcode: 'ITEM', goodId: 'g1', symbology: null),
      ]);
      await cache.addBarcode(barcode: 'BOX', goodId: 'g1');
      expect((await cache.barcodesOfGood('g1')).length, 2);

      await cache.removeBarcode('BOX');
      final left = await cache.barcodesOfGood('g1');
      expect(left.map((b) => b.barcode), ['ITEM']);
    });
  });
}
