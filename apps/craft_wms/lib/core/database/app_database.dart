import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:injectable/injectable.dart';

import '../config/app_config.dart';

part 'app_database.g.dart';

/// Локальная база устройства (P2-02): кэш справочников для работы без сети.
///
/// Что здесь лежит: только **справочники** - товары, группы, поставщики, ячейки, штрихкоды.
/// Их меняет импорт из 1С и печать этикеток, то есть события редкие и внешние по отношению
/// к работе кладовщика.
///
/// Остатки по товару здесь не лежат: карточка товара в «Остатках» ходит только в сеть
/// (решение P2-02, долг 22). С P5-05 здесь лежит **снимок содержимого склада** - живые короба
/// и россыпь по ячейкам: кладовщик сканирует ячейку или короб и без связи, а экран честно
/// пишет, на какой момент данные (см. [CachedLoadUnits]).

/// Товары. Префикс `Cached` во всех таблицах - не украшение: drift генерирует для таблицы
/// класс строки в единственном числе, и таблица `Goods` дала бы класс `Good`, столкнувшись
/// с доменной моделью того же имени. Префикс заодно сразу говорит, что это копия, а не
/// источник истины.
///
/// `searchText` - предрассчитанная нормализованная склейка названия, кода и полного
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

  /// Маркируемый товар (CZ-05), см. `Good.czMarked`.
  BoolColumn get czMarked => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Группы номенклатуры - дерево через `parentId`. Фильтр по группе работает по ПОДДЕРЕВУ
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

  /// Ячейка приёмки по умолчанию («ПРИЁМКА»), см. `Cell.isDefault` (P4-09).
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// Адрес в нижнем регистре - резолв по скану идёт регистронезависимо, а сравнивать
  /// готовое поле дешевле, чем звать `LOWER()` на каждой строке.
  TextColumn get addressLower => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Привязки штрихкодов к товарам. Один ШК указывает ровно на один товар (`barcode` - ключ),
/// у товара их может быть несколько - штука и короб (P-FS-11).
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

/// Настройки устройства - пары «ключ → значение» (P4-05).
///
/// Что: мелкие настройки, которые принадлежат конкретному терминалу, а не учётной записи:
/// выбранный принтер и язык его команд.
/// Зачем в базе, а не в защищённом хранилище: это не секреты, а рабочие предпочтения; у
/// `flutter_secure_storage` своё назначение - токены. Отдельная таблица на каждую настройку
/// завела бы миграцию под каждую мелочь.
/// Как: значение всегда строкой - разбор на стороне того, кто настройку завёл. Типизировать
/// общее хранилище значило бы тащить в схему всё, что когда-нибудь понадобится сохранить.
class DeviceSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Очередь исходящих операций (Outbox, P2-03).
///
/// Что: операция, которую устройство должно донести до сервера, - сначала строка здесь,
/// и только потом сетевой вызов.
/// Зачем: сеть на складе проседает (стеллажи, металл), и операция, живущая только в памяти,
/// исчезает вместе с процессом. Строка в базе переживает и обрыв связи, и перезапуск.
/// Как: FIFO по [seq]; [operationId] - UUID v4, ключ идемпотентности, по которому сервер
/// отбросит повтор (P2-05); тело запроса лежит в [payload] строкой JSON.
///
/// ⚠ Отличие от таблиц `Cached*` принципиальное: кэш справочников одноразовый, его всегда можно
/// перекачать с сервера. Строка Outbox - **единственная копия работы кладовщика**, и потерять её
/// значит потерять сам факт операции. Отсюда требование к будущим миграциям: таблицу переносить,
/// а не пересоздавать.
/// ⚠ Имя класса строки задано явно. По умолчанию drift выводит его из имени таблицы в
/// единственном числе, и `OutboxOperations` дал бы `OutboxOperation` - ровно имя доменного
/// класса очереди. Таблицы `Cached*` решают то же столкновение префиксом; здесь аннотация
/// точнее: переименовывать саму таблицу ради генератора незачем.
@DataClassName('OutboxRow')
class OutboxOperations extends Table {
  /// Порядковый номер - он же порядок отправки. Отдельная колонка, а не `createdAt`: метки
  /// времени в пределах одной миллисекунды совпадают, и порядок двух операций стал бы
  /// неопределённым - а для пары «привязать ШК» / «отвязать ШК» он решает исход.
  IntColumn get seq => integer().autoIncrement()();

  /// Ключ идемпотентности (UUID v4). Уникален: повторная постановка той же операции невозможна.
  TextColumn get operationId => text().unique()();

  /// Тип операции - значение [OutboxKind]. Строкой, а не индексом enum: индексы поедут при
  /// вставке нового значения в середину, а строки в уже записанных строках останутся верными.
  TextColumn get kind => text()();

  /// Тело запроса, JSON. Форма зависит от [kind] и разбирается отправщиком.
  TextColumn get payload => text()();

  /// Стадия жизни операции - значение [OutboxStatus]; тоже строкой и по той же причине.
  TextColumn get status => text()();

  /// Сколько раз пытались отправить. Наполняется в P2-04 (ретраи с backoff).
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Текст последней неудачи - для диагностики и экрана разбора (P2-06).
  TextColumn get lastError => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// Черновики незавершённой работы: проход «Ввода остатков» (P2-03) и приёмка (P4-09).
///
/// Что: слепок работы - у прохода текущая ячейка, её строки и пройденные ячейки, у приёмки
/// поставщик, короба и строки - одной строкой JSON.
/// Зачем: работа копится на терминале и уходит на сервер одним махом в конце. До этого момента
/// падение приложения, разряд батареи или выгрузка процесса Android'ом теряли бы её целиком -
/// и происходило это при исправной сети, то есть к офлайну отношения не имеет.
/// Как: строка на поток, переписывается на каждом изменении и удаляется на финале.
///
/// Почему JSON, а не нормализованные таблицы: читатель у этих данных один - сам экран потока;
/// запросов по ним не делается, только чтение целиком при восстановлении.
/// Нормализация дала бы четыре таблицы и джойны ради операции «прочитать всё».
///
/// Таблица общая для потоков: строка на поток, ключ - имя потока (`current` у прохода, имя
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

/// Текущие задания склада (P5-02-1) - снимок последнего ответа `GET /tasks`.
///
/// Зачем: задание выполняется без связи, а значит, и список текущих, и позиции задания должны
/// открываться офлайн. Взять задание без связи нельзя (кто его держит, знает только сервер),
/// поэтому снимок - только для чтения и заменяется целиком при каждом удачном запросе.
///
/// Одна строка со списком, а не строка на задание: пустой список - тоже ответ сервера
/// («заданий нет»), и его нельзя путать с отсутствием снимка («ещё ни разу не было связи»).
/// Строки на задание этого различия не держали бы. JSON - по той же причине, что черновики:
/// читатель один - экран заданий.
class CachedTasks extends Table {
  /// Ключ снимка: он один.
  TextColumn get id => text().withDefault(const Constant('current'))();

  /// Список заданий целиком, JSON ответа сервера.
  TextColumn get payload => text()();

  /// Когда снимок получен с сервера - показывается кладовщику без связи.
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Живые короба из снимка содержимого склада (P5-05) - `GET /contents/snapshot`.
///
/// Зачем: скан ячейки или короба без связи показывает, что внутри. Снимок заменяется целиком
/// (как справочники): сервер отдаёт только живые короба, и выведенные из обращения иначе
/// остались бы здесь навсегда. Свои неотправленные приёмки и размещения сюда НЕ пишутся -
/// следующая замена их стёрла бы; они накладываются при чтении (`PendingOverlay`).
///
/// Таблицы, а не JSON одной строкой, как у заданий: читают снимок по ячейке и по коробу,
/// а разбирать ради одного короба весь склад - лишняя работа на каждый скан.
@TableIndex(name: 'cached_load_units_cell', columns: {#cellId})
class CachedLoadUnits extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get cellId => text()();
  DateTimeColumn get createdAt => dateTime()();

  /// Внутренний склад короба целиком (P6-07-1): «Основной», «Брак», «Изолятор» … Пусто -
  /// снимок сервера без склада у коробов (до P6-07-1): короб «Основной».
  TextColumn get internalWarehouseId =>
      text().withDefault(const Constant(''))();

  /// Код короба ЧЗ (`00`+SSCC) - короб узнаётся сканом этикетки ЧЗ без связи (CZ-06);
  /// `null` - свой короб с QR.
  TextColumn get czCode => text().nullable()();

  /// Короб ЧЗ вскрыт: из него вынута хоть одна марка (CZ-06).
  BoolColumn get czOpened => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Марки ЧЗ на складе из снимка (CZ-06): что за единицу отсканировали и где она лежит, -
/// перемещение маркируемого товара идёт марками и без связи.
///
/// Место - как на сервере: [loadUnitId] (в коробе; ячейка - у короба) или [cellId] со складом
/// [internalWarehouseId] (россыпью). [aggregateCode] - упаковка ЧЗ, в которой марка пришла:
/// скан групповой упаковки - набор марок с этим кодом.
@TableIndex(name: 'cached_cz_marks_lu', columns: {#loadUnitId})
@TableIndex(name: 'cached_cz_marks_cell', columns: {#cellId})
@TableIndex(name: 'cached_cz_marks_aggregate', columns: {#aggregateCode})
class CachedCzMarks extends Table {
  TextColumn get cis => text()();
  TextColumn get goodId => text()();
  TextColumn get batchId => text()();

  /// Дата партии в транспортном виде DD-MM-YYYY.
  TextColumn get productionDate => text()();
  TextColumn get loadUnitId => text().nullable()();
  TextColumn get cellId => text().nullable()();
  TextColumn get internalWarehouseId => text().nullable()();
  TextColumn get aggregateCode => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {cis};
}

/// Содержимое коробов снимка: товар партии с количеством.
///
/// Партия хранится и идентификатором, и датой: дата - то, что видит человек и что несут
/// операции очереди (по ней наложение сводит строки), идентификатор - ключ строки.
@TableIndex(name: 'cached_load_unit_lines_lu', columns: {#loadUnitId})
class CachedLoadUnitLines extends Table {
  TextColumn get loadUnitId => text()();
  TextColumn get goodId => text()();
  TextColumn get batchId => text()();

  /// Дата партии в транспортном виде DD-MM-YYYY.
  TextColumn get productionDate => text()();
  RealColumn get qty => real()();

  @override
  Set<Column<Object>> get primaryKey => {loadUnitId, goodId, batchId};
}

/// Россыпь снимка: товар партии в ячейке вне коробов.
@TableIndex(name: 'cached_loose_stock_cell', columns: {#cellId})
class CachedLooseStock extends Table {
  TextColumn get cellId => text()();
  TextColumn get internalWarehouseId => text()();
  TextColumn get goodId => text()();
  TextColumn get batchId => text()();

  /// Дата партии в транспортном виде DD-MM-YYYY.
  TextColumn get productionDate => text()();
  RealColumn get qty => real()();

  /// Сколько из [qty] уже в сборке (P9-06): показ «20 шт. (5 шт. в сборке)».
  RealColumn get inPicking => real().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {
    cellId,
    goodId,
    batchId,
    internalWarehouseId,
  };
}

/// Внутренние склады (P6-07-2): «Основной», «Брак», «Изолятор» … - чтобы пометить товар
/// браком без связи и подписать его на экранах.
class CachedInternalWarehouses extends Table {
  TextColumn get id => text()();
  TextColumn get code => text()();
  TextColumn get name => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// Склад в выборе (ADHOC-29): скрытым не помечают, но его остаток подписывается.
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Причины проблем склада (ADHOC-55): справочник офиса - выбрать причину при пометке без
/// связи и подписать ею проблемы.
class CachedProblemReasons extends Table {
  TextColumn get code => text()();
  TextColumn get name => text()();

  /// Порядок справочника.
  IntColumn get ord => integer()();

  /// Кладовщик выбирает её на ТСД; нет - ставит только программа.
  BoolColumn get manual => boolean().withDefault(const Constant(true))();
  BoolColumn get commentRequired =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {code};
}

/// Очередь фото к проблемам склада (ADHOC-45): снимки, ещё не загруженные на сервер.
///
/// Отдельно от очереди операций: снимок весит сотни килобайт, и в теле операции он задерживал
/// бы всё, что стоит за ним. Снимок грузится после того, как проблема дошла до сервера, и
/// удаляется отсюда, как только сервер его принял. Сам снимок - здесь же, в базе: переживает
/// перезапуск, а файлов, которые пришлось бы чистить, нет.
class ProblemPhotoUploads extends Table {
  /// Идентификатор снимка - выдаёт терминал; повтор загрузки сервер не задваивает.
  TextColumn get id => text()();
  TextColumn get problemId => text()();
  BlobColumn get content => blob()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Подключение к локальной базе.
///
/// Файл `craft_wms.sqlite` (в демо-режиме - `craft_wms_demo.sqlite`) в каталоге приложения; при удалении приложения уходит вместе с ним.
/// Секретов здесь нет - только справочные данные, поэтому шифрование не подключаем
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
    CachedTasks,
    CachedLoadUnits,
    CachedLoadUnitLines,
    CachedLooseStock,
    CachedInternalWarehouses,
    ProblemPhotoUploads,
    CachedCzMarks,
    CachedProblemReasons,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: fileName));

  /// Имя файла базы. У демо-режима свой файл (ADHOC-67): очередь и снимки рабочего склада и
  /// демо-склада не смешиваются, а вход в демо начинается с чистой базы.
  static String get fileName => AppConfig.isDemo ? demoFileName : 'craft_wms';

  /// Имя файла базы демо-режима (без `.sqlite`).
  static const demoFileName = 'craft_wms_demo';

  /// Тестовый конструктор: база в памяти, без файла на диске.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 14;

  /// Миграции схемы.
  ///
  /// До P2-03 стратегии не было вовсе: схема жила в версии 1 и ни разу не менялась. На
  /// терминалах эта база уже лежит с наполненными справочниками, поэтому подъём версии без
  /// стратегии уронил бы открытие базы у всех, кто обновится, а не у новых установок.
  ///
  /// 1 → 2: добавлены [outboxOperations] и [entryDrafts]. Существующие таблицы не трогаем -
  /// пересоздание кэша стоило бы повторной синхронизации, а его данные и так на месте.
  ///
  /// 2 → 3: у привязок ШК появилась пометка «ещё не подтверждена сервером» (P2-06).
  ///
  /// 3 → 4: добавлены [deviceSettings] - выбранный принтер и язык его команд (P4-05).
  ///
  /// 4 → 5: у ячеек появился признак дефолтной ячейки приёмки (P4-09).
  ///
  /// 5 → 6: добавлены [cachedTasks] - снимок текущих заданий склада (P5-02-1).
  ///
  /// 6 → 7: добавлены таблицы снимка содержимого склада - [cachedLoadUnits],
  /// [cachedLoadUnitLines], [cachedLooseStock] (P5-05). Пустые до первой загрузки снимка.
  ///
  /// 7 → 8: у коробов снимка - внутренний склад, добавлен справочник внутренних складов
  /// [cachedInternalWarehouses] (P6-07-2).
  ///
  /// 8 → 9: у внутренних складов - признак «в выборе» (ADHOC-29): скрытые портал оставляет
  /// в справочнике ради подписи их остатка.
  ///
  /// 9 → 10: у товаров - признак «маркируемый» (CZ-05).
  ///
  /// 10 → 11: очередь фото к проблемам склада [problemPhotoUploads] (ADHOC-45).
  ///
  /// 11 → 12: у коробов снимка - код короба ЧЗ и признак вскрытия, марки ЧЗ на складе
  /// [cachedCzMarks] (CZ-06).
  ///
  /// 12 → 13: справочник причин проблем [cachedProblemReasons] (ADHOC-55). Пуст до первой
  /// синхронизации - до неё форма пометки берёт прежний список причин.
  ///
  /// 13 → 14: у россыпи снимка - «в сборке» (P9-06).
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
        // становятся подтверждёнными - они и есть подтверждённые, их принёс сервер.
        await m.addColumn(cachedBarcodes, cachedBarcodes.pending);
      }
      if (from < 4) {
        await m.createTable(deviceSettings);
      }
      if (from < 5) {
        await m.addColumn(cachedCells, cachedCells.isDefault);
        // Колонка встаёт со значением «нет» у всех ячеек, то есть кэш тут же начинает врать:
        // дефолтная ячейка в нём есть, но не помечена. Снимаем отметку о загрузке ячеек -
        // до следующей синхронизации справочник читается с сервера, где флаг верный.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('cells'))).go();
      }
      if (from < 6) {
        await m.createTable(cachedTasks);
      }
      if (from < 7) {
        // Индексы (@TableIndex) createTable создаёт вместе с таблицей - отдельный createIndex
        // падал бы на «index already exists» (поймано тестом миграции).
        await m.createTable(cachedLoadUnits);
        await m.createTable(cachedLoadUnitLines);
        await m.createTable(cachedLooseStock);
      }
      if (from < 8) {
        // Колонку добавляем только базе версии 7: при подъёме с более ранних таблицу коробов
        // только что создал шаг «< 7» - по текущей схеме, уже с колонкой (поймано тестом
        // миграции).
        if (from == 7) {
          await m.addColumn(
            cachedLoadUnits,
            cachedLoadUnits.internalWarehouseId,
          );
        }
        await m.createTable(cachedInternalWarehouses);
        // Склад встаёт пустым у всех коробов - бракованный короб выглядел бы «Основным».
        // Снимаем отметку снимка: до следующей загрузки содержимое читается с сервера.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('contents'))).go();
      }
      if (from == 8) {
        // Только базе версии 8: с более ранних справочник складов только что создан шагом
        // «< 8» по текущей схеме - уже с колонкой. Встаёт «в выборе» у всех: следующая
        // синхронизация принесёт настоящие признаки.
        await m.addColumn(
          cachedInternalWarehouses,
          cachedInternalWarehouses.isActive,
        );
      }
      // Только при подъёме до 10 и выше: таблица товаров живёт с версии 1, и тесты прежних
      // шагов (onUpgrade(2, 3) по базе текущей схемы) иначе добавляли бы колонку повторно.
      if (from < 10 && to >= 10) {
        await m.addColumn(cachedGoods, cachedGoods.czMarked);
        // Признак встаёт «нет» у всех товаров - маркируемый товар принимался бы по ШК.
        // Снимаем отметку товаров: до следующей загрузки справочник читается с сервера.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('goods'))).go();
      }
      // Только при подъёме до 11 и выше - по той же причине, что у шага 10.
      if (from < 11 && to >= 11) {
        await m.createTable(problemPhotoUploads);
      }
      if (from < 12 && to >= 12) {
        // Колонки - только базе, где таблица коробов уже была (версия 7 и выше): с более
        // ранних её только что создал шаг «< 7» по текущей схеме.
        if (from >= 7) {
          await m.addColumn(cachedLoadUnits, cachedLoadUnits.czCode);
          await m.addColumn(cachedLoadUnits, cachedLoadUnits.czOpened);
        }
        await m.createTable(cachedCzMarks);
        // Снимок без марок и кодов коробов ЧЗ: короб ЧЗ не нашёлся бы по скану, а марки -
        // вовсе. Снимаем отметку снимка: до следующей загрузки содержимое читается с сервера.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('contents'))).go();
      }
      if (from < 13 && to >= 13) {
        await m.createTable(cachedProblemReasons);
      }
      if (from < 14 && to >= 14) {
        // Колонку - только базе, где таблица россыпи уже была (версия 7 и выше): с более
        // ранних её только что создал шаг «< 7» по текущей схеме.
        if (from >= 7) {
          await m.addColumn(cachedLooseStock, cachedLooseStock.inPicking);
        }
        // Встаёт нулём у всей россыпи - взятое в сборку не было бы видно до новой загрузки.
        // Снимаем отметку снимка: до следующей загрузки содержимое читается с сервера.
        await (delete(
          catalogSyncMarks,
        )..where((t) => t.catalog.equals('contents'))).go();
      }
    },
  );
}
