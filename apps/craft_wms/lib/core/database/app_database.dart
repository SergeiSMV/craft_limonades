import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:injectable/injectable.dart';

part 'app_database.g.dart';

/// Локальная база устройства (P2-02): кэш справочников для работы без сети.
///
/// Что здесь лежит: только **справочники** — товары, группы, поставщики, ячейки, штрихкоды.
/// Их меняет импорт из 1С и печать этикеток, то есть события редкие и внешние по отношению
/// к работе кладовщика.
///
/// Чего здесь НЕТ: **остатков**. Остаток меняется от каждой операции любого терминала, и
/// показать кладовщику число, которое уже неверно, хуже честного «нет связи» — по неверному
/// он примет решение. Раздел «Остатки» офлайн отдаёт список товаров из кэша, а карточку
/// остатков — только по сети (решение пользователя, P2-02).

/// Товары. Префикс `Cached` во всех таблицах — не украшение: drift генерирует для таблицы
/// класс строки в единственном числе, и таблица `Goods` дала бы класс `Good`, столкнувшись
/// с доменной моделью того же имени. Префикс заодно сразу говорит, что это копия, а не
/// источник истины.
///
/// `searchText` — предрассчитанная нормализованная склейка названия, кода и полного
/// названия: локальный поиск сравнивает одно поле вместо трёх, а нормализация («ё» → «е»,
/// нижний регистр) выполняется один раз при укладке, а не на каждый запрос.
class CachedGoods extends Table {
  TextColumn get id => text()();
  TextColumn get code => text().nullable()();
  TextColumn get name => text()();
  TextColumn get fullName => text().nullable()();
  TextColumn get uom => text()();
  TextColumn get groupId => text().nullable()();
  TextColumn get groupName => text().nullable()();
  TextColumn get supplierId => text().nullable()();
  TextColumn get supplierName => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get searchText => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Группы номенклатуры — дерево через `parentId`. Фильтр по группе работает по ПОДДЕРЕВУ
/// (выбор родителя не должен давать пусто), поэтому дерево нужно целиком.
class CachedGroups extends Table {
  TextColumn get id => text()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Поставщики.
class CachedSuppliers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Физические ячейки склада.
class CachedCells extends Table {
  TextColumn get id => text()();
  TextColumn get warehouseId => text()();
  TextColumn get address => text()();
  TextColumn get type => text().withDefault(const Constant('storage'))();
  BoolColumn get isFloor => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Адрес в нижнем регистре — резолв по скану идёт регистронезависимо, а сравнивать
  /// готовое поле дешевле, чем звать `LOWER()` на каждой строке.
  TextColumn get addressLower => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Привязки штрихкодов к товарам. Один ШК указывает ровно на один товар (`barcode` — ключ),
/// у товара их может быть несколько — штука и короб (P-FS-11).
class CachedBarcodes extends Table {
  TextColumn get barcode => text()();
  TextColumn get goodId => text()();
  TextColumn get symbology => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {barcode};
}

/// Отметки о последней успешной загрузке каждого справочника.
///
/// Зачем: по ним видно, насколько кэш свеж, и можно честно сказать пользователю, данные
/// какого времени он смотрит. Одна строка на справочник, а не одна на всю базу: справочники
/// обновляются независимо, и общая отметка врала бы про те, что не обновились.
class CatalogSyncMarks extends Table {
  TextColumn get catalog => text()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {catalog};
}

/// Подключение к локальной базе.
///
/// Файл `craft_wms.sqlite` в каталоге приложения; при удалении приложения уходит вместе с ним.
/// Секретов здесь нет — только справочные данные, поэтому шифрование не подключаем
/// (токены по-прежнему живут в secure storage).
@lazySingleton
@DriftDatabase(
  tables: [
    CachedGoods,
    CachedGroups,
    CachedSuppliers,
    CachedCells,
    CachedBarcodes,
    CatalogSyncMarks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'craft_wms'));

  /// Тестовый конструктор: база в памяти, без файла на диске.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;
}
