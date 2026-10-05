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

  /// Ячейка приёмки по умолчанию («С-Н-П»), см. `Cell.isDefault` (P4-09).
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

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

  /// Привязка сделана на устройстве и сервером ещё не подтверждена (P2-06).
  ///
  /// Без этой пометки оптимистичная запись неотличима от факта справочника: кладовщик видел бы
  /// ШК в карточке и считал дело сделанным, хотя операция ещё в очереди и может быть отклонена.
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

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

/// Настройки устройства — пары «ключ → значение» (P4-05).
///
/// Что: мелкие настройки, которые принадлежат конкретному терминалу, а не учётной записи:
/// выбранный принтер и язык его команд.
/// Зачем в базе, а не в защищённом хранилище: это не секреты, а рабочие предпочтения; у
/// `flutter_secure_storage` своё назначение — токены. Отдельная таблица на каждую настройку
/// завела бы миграцию под каждую мелочь.
/// Как: значение всегда строкой — разбор на стороне того, кто настройку завёл. Типизировать
/// общее хранилище значило бы тащить в схему всё, что когда-нибудь понадобится сохранить.
class DeviceSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Очередь исходящих операций (Outbox, P2-03).
///
/// Что: операция, которую устройство должно донести до сервера, — сначала строка здесь,
/// и только потом сетевой вызов.
/// Зачем: сеть на складе проседает (стеллажи, металл), и операция, живущая только в памяти,
/// исчезает вместе с процессом. Строка в базе переживает и обрыв связи, и перезапуск.
/// Как: FIFO по [seq]; [operationId] — UUID v4, ключ идемпотентности, по которому сервер
/// отбросит повтор (P2-05); тело запроса лежит в [payload] строкой JSON.
///
/// ⚠ Отличие от таблиц `Cached*` принципиальное: кэш справочников одноразовый, его всегда можно
/// перекачать с сервера. Строка Outbox — **единственная копия работы кладовщика**, и потерять её
/// значит потерять сам факт операции. Отсюда требование к будущим миграциям: таблицу переносить,
/// а не пересоздавать.
/// ⚠ Имя класса строки задано явно. По умолчанию drift выводит его из имени таблицы в
/// единственном числе, и `OutboxOperations` дал бы `OutboxOperation` — ровно имя доменного
/// класса очереди. Таблицы `Cached*` решают то же столкновение префиксом; здесь аннотация
/// точнее: переименовывать саму таблицу ради генератора незачем.
@DataClassName('OutboxRow')
class OutboxOperations extends Table {
  /// Порядковый номер — он же порядок отправки. Отдельная колонка, а не `createdAt`: метки
  /// времени в пределах одной миллисекунды совпадают, и порядок двух операций стал бы
  /// неопределённым — а для пары «привязать ШК» / «отвязать ШК» он решает исход.
  IntColumn get seq => integer().autoIncrement()();

  /// Ключ идемпотентности (UUID v4). Уникален: повторная постановка той же операции невозможна.
  TextColumn get operationId => text().unique()();

  /// Тип операции — значение [OutboxKind]. Строкой, а не индексом enum: индексы поедут при
  /// вставке нового значения в середину, а строки в уже записанных строках останутся верными.
  TextColumn get kind => text()();

  /// Тело запроса, JSON. Форма зависит от [kind] и разбирается отправщиком.
  TextColumn get payload => text()();

  /// Стадия жизни операции — значение [OutboxStatus]; тоже строкой и по той же причине.
  TextColumn get status => text()();

  /// Сколько раз пытались отправить. Наполняется в P2-04 (ретраи с backoff).
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Текст последней неудачи — для диагностики и экрана разбора (P2-06).
  TextColumn get lastError => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// Черновики незавершённой работы: проход «Ввода остатков» (P2-03) и приёмка (P4-09).
///
/// Что: слепок работы — у прохода текущая ячейка, её строки и пройденные ячейки, у приёмки
/// поставщик, короба и строки — одной строкой JSON.
/// Зачем: работа копится на терминале и уходит на сервер одним махом в конце. До этого момента
/// падение приложения, разряд батареи или выгрузка процесса Android'ом теряли бы её целиком —
/// и происходило это при исправной сети, то есть к офлайну отношения не имеет.
/// Как: строка на поток, переписывается на каждом изменении и удаляется на финале.
///
/// Почему JSON, а не нормализованные таблицы: читатель у этих данных один — сам экран потока;
/// запросов по ним не делается, только чтение целиком при восстановлении.
/// Нормализация дала бы четыре таблицы и джойны ради операции «прочитать всё».
///
/// Таблица общая для потоков: строка на поток, ключ — имя потока (`current` у прохода, имя
/// осталось с тех пор, когда черновик был один; `receipt` у приёмки). Новая таблица под каждый
/// поток дала бы миграцию на каждый поток ради одной и той же пары «ключ → JSON».
class EntryDrafts extends Table {
  /// Ключ потока: черновик у каждого потока один.
  TextColumn get id => text().withDefault(const Constant('current'))();

  /// Слепок состояния, JSON.
  TextColumn get payload => text()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
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
    OutboxOperations,
    EntryDrafts,
    DeviceSettings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'craft_wms'));

  /// Тестовый конструктор: база в памяти, без файла на диске.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  /// Миграции схемы.
  ///
  /// До P2-03 стратегии не было вовсе: схема жила в версии 1 и ни разу не менялась. На
  /// терминалах эта база уже лежит с наполненными справочниками, поэтому подъём версии без
  /// стратегии уронил бы открытие базы у всех, кто обновится, а не у новых установок.
  ///
  /// 1 → 2: добавлены [outboxOperations] и [entryDrafts]. Существующие таблицы не трогаем —
  /// пересоздание кэша стоило бы повторной синхронизации, а его данные и так на месте.
  ///
  /// 2 → 3: у привязок ШК появилась пометка «ещё не подтверждена сервером» (P2-06).
  ///
  /// 3 → 4: добавлены [deviceSettings] — выбранный принтер и язык его команд (P4-05).
  ///
  /// 4 → 5: у ячеек появился признак дефолтной ячейки приёмки (P4-09).
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(outboxOperations);
        await m.createTable(entryDrafts);
      }
      if (from < 3) {
        // Колонка добавляется со значением по умолчанию, поэтому уже лежащие привязки
        // становятся подтверждёнными — они и есть подтверждённые, их принёс сервер.
        await m.addColumn(cachedBarcodes, cachedBarcodes.pending);
      }
      if (from < 4) {
        await m.createTable(deviceSettings);
      }
      if (from < 5) {
        await m.addColumn(cachedCells, cachedCells.isDefault);
        // Колонка встаёт со значением «нет» у всех ячеек, то есть кэш тут же начинает врать:
        // дефолтная ячейка в нём есть, но не помечена. Снимаем отметку о загрузке ячеек —
        // до следующей синхронизации справочник читается с сервера, где флаг верный.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('cells'))).go();
      }
    },
  );
}
