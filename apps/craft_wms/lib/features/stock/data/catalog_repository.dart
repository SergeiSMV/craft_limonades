import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_effects.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/sync/sync_engine.dart';
import 'catalog_api.dart';
import 'catalog_cache.dart';
import 'catalog_models.dart';

/// Репозиторий справочников: сначала локальный кэш, сеть — там, где кэша быть не может (P2-02).
///
/// Что: единая точка доступа к справочникам и остаткам для всех экранов.
/// Зачем: экраны не должны знать, откуда пришли данные, — иначе каждый обзаведётся своей
///        логикой «есть ли сеть», и они разъедутся.
/// Как: справочники читаются из [CatalogCache]; в сеть ([CatalogApi]) уходят только остатки,
///      записи (привязка и отвязка ШК) и чтения до первой синхронизации кэша.
///
/// Публичная поверхность намеренно совпадает с прежней, сетевой версией: переход на кэш не
/// потребовал правок ни в одном cubit и ни в одном виджете.
@lazySingleton
class CatalogRepository {
  CatalogRepository(
    this._api,
    this._cache,
    this._outbox,
    this._effects,
    this._sync,
  );

  final CatalogApi _api;
  final CatalogCache _cache;
  final OutboxRepository _outbox;
  final OutboxEffects _effects;
  final SyncEngine _sync;

  /// Запомненные справочники, уже лежащие в кэше. Проверять базу на каждый вызов незачем:
  /// обратно в «пусто» справочник не возвращается, а пополняется синхронизацией.
  Set<String> _loaded = const {};

  /// Готов ли конкретный справочник. Готовность считается по каждому отдельно: один
  /// недоступный справочник не должен отключать офлайн для остальных.
  Future<bool> _ready(String catalog) async {
    if (_loaded.contains(catalog)) return true;
    _loaded = await _cache.loadedCatalogs();
    return _loaded.contains(catalog);
  }

  /// Список/поиск товаров. Из кэша — с поиском «все слова присутствуют» и фильтром по поддереву
  /// групп, как на сервере (P-FS-17, P1-07). До первой синхронизации — сетью.
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) async {
    if (!await _ready(CatalogName.goods)) {
      return _api.listGoods(
        query: query,
        groupId: groupId,
        supplierId: supplierId,
        limit: limit,
        offset: offset,
      );
    }
    // Поддерево группы разворачиваем здесь: кэш хранит плоский список, а дерево нужно целиком.
    List<String>? groupIds;
    // Развернуть поддерево можно только по загруженному дереву групп; без него фильтр
    // применяем как есть — по самой группе, без вложенных.
    if (groupId != null && groupId.isNotEmpty) {
      if (!await _ready(CatalogName.groups)) {
        groupIds = [groupId];
      } else {
        groupIds = CatalogCache.descendantGroupIds(
          await _cache.groups(),
          groupId,
        );
      }
    }
    return Right(
      await _cache.searchGoods(
        query: query,
        groupIds: groupIds,
        supplierId: supplierId,
        limit: limit,
        offset: offset,
      ),
    );
  }

  /// Товар по штрихкоду. `Right(null)` — ШК не привязан ни к одному товару (это ответ сервера,
  /// штатный исход); `Left` — спросить не удалось, и привязан ШК или нет, неизвестно.
  ///
  /// Порядок: кэш → сеть. Промах кэша сам по себе не значит «не привязан»: привязку могли
  /// сделать на другом терминале после нашей последней синхронизации, поэтому за окончательным
  /// ответом идём на сервер.
  ///
  /// Сетевой отказ намеренно НЕ превращается в `Right(null)` (ADHOC-06). Раньше превращался, и
  /// офлайн экран утверждал «ШК не привязан ни к одному товару» — то есть выдавал догадку за
  /// факт, проверить который было нечем. Цена ошибки несимметрична: по такому ответу кладовщик
  /// привязывает ШК к товару, а привязка уже есть на сервере за другим товаром — вместо чтения
  /// получаем порчу справочника. Теперь отказ доходит до экрана как есть.
  Future<Either<Failure, Good?>> resolveGoodByBarcode(String code) async {
    if (await _ready(CatalogName.barcodes)) {
      final local = await _cache.goodByBarcode(code);
      if (local != null) return Right(local);
    }
    return _api.resolveGoodByBarcode(code);
  }

  /// Товар по идентификатору из справочника терминала; `null` — справочник не загружен или
  /// товара в нём нет (заведён после загрузки). Нужен переходу в карточку товара из содержимого
  /// короба (P5-05-1), где известен только идентификатор и наименование.
  Future<Good?> goodById(String id) async =>
      await _ready(CatalogName.goods) ? _cache.goodById(id) : null;

  /// Штрихкоды товара (секция «Штрихкоды» карточки). Пустой список — норма.
  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId) async {
    if (!await _ready(CatalogName.barcodes)) {
      return _api.listGoodBarcodes(goodId);
    }
    return Right(await _cache.barcodesOfGood(goodId));
  }

  /// Привязать ШК к товару.
  ///
  /// Порядок: операция в очередь → локальное следствие с пометкой «ожидает» → попытка
  /// отправить прямо сейчас. Кладовщик видит результат немедленно, даже без связи, а пометка
  /// не даёт принять неподтверждённую привязку за факт справочника (P2-06).
  ///
  /// [fromCzMark] — ШК взят из марки ЧЗ (CZ-05): сервер заодно помечает товар маркируемым,
  /// кэш — сразу, следствием операции.
  Future<Either<Failure, void>> bindBarcode({
    required String goodId,
    required String barcode,
    bool fromCzMark = false,
  }) => _enqueueAndSend(
    kind: OutboxKind.bindBarcode,
    payload: {
      'good_id': goodId,
      'barcode': barcode,
      if (fromCzMark) 'from_cz_mark': true,
    },
  );

  /// Выдать товару внутренний штрихкод (P4-07) — **только по сети**.
  ///
  /// В очередь операция не ставится сознательно (решение P4-09): код обязан быть уникален во
  /// всей системе, а офлайн-выдача этого не обещает без диапазонов номеров, выданных терминалу
  /// заранее. Без связи кладовщик получает отказ и может принять товар без печати ярлыка.
  ///
  /// Выданный код сразу кладётся в кэш подтверждённым: его выдал сервер, ждать нечего, а скан
  /// только что напечатанного ярлыка без связи иначе не опознал бы товар.
  Future<Either<Failure, IssuedBarcode>> issueInternalBarcode(
    String goodId,
  ) async {
    final res = await _api.issueInternalBarcode(goodId);
    if (res.isRight) {
      await _cache.addBarcode(
        barcode: res.right.barcode,
        goodId: goodId,
        symbology: res.right.symbology,
      );
    }
    return res;
  }

  /// Ячейка приёмки по умолчанию («С-Н-П») — из кэша, а без него по сети (P4-09).
  ///
  /// `Right(null)` — справочник прочитан, а дефолтной ячейки в нём нет: склад развёрнут не до
  /// конца, и это повод звать админа, а не ошибка связи.
  Future<Either<Failure, Cell?>> defaultCell() async {
    final res = await listAllCells();
    return res.map((cells) => cells.where((c) => c.isDefault).firstOrNull);
  }

  /// Отвязать ШК.
  ///
  /// `good_id` кладётся в тело операции не для запроса — серверу он не нужен, — а чтобы при
  /// отказе было чем вернуть привязку в кэш.
  Future<Either<Failure, void>> unbindBarcode({
    required String goodId,
    required String barcode,
  }) => _enqueueAndSend(
    kind: OutboxKind.unbindBarcode,
    payload: {'good_id': goodId, 'barcode': barcode},
  );

  /// Отменить привязку ШК, которая ещё НЕ ушла на сервер (ADHOC-14).
  ///
  /// Что: снимает из очереди операцию привязки этого кода и убирает её след из кэша.
  /// Зачем: в проходе «Ввод остатков» кладовщик может отменить последний шаг — а привязка,
  ///        сделанная на этом шаге, теперь обычная операция очереди, а не запись в памяти.
  /// Как: ищем среди ожидающих операцию привязки этого кода; нашли — выбрасываем и откатываем
  ///      локальное следствие.
  ///
  /// **Отменяется только то, что ещё не ушло** (решение пользователя): статус `pending`.
  /// Операция в статусе `sending` уже в полёте, её судьба на сервере неизвестна, и отзывать её
  /// нечем — отмена превратилась бы в обещание, которого приложение не выполняет.
  ///
  /// Возвращает `true`, если успели. `false` означает «поздно» — привязка либо уже на сервере,
  /// либо в пути; вызывающий решает, показывать ли это и предлагать ли отвязку.
  ///
  /// Гонка с движком синхронизации закрыта (долг 13): чтение очереди здесь лишь находит
  /// кандидата, а решает условное снятие [OutboxRepository.discardIfPending] — оно удаляет
  /// строку, только если та всё ещё `pending`. Движок, в свою очередь, забирает операцию
  /// в отправку лишь если строка на месте. Кто из двух успел первым — того и исход.
  Future<bool> cancelPendingBind(String barcode) async {
    final waiting = await _outbox.pending();
    final match = waiting
        .where(
          (op) =>
              op.kind == OutboxKind.bindBarcode &&
              op.status == OutboxStatus.pending &&
              op.payload['barcode'] == barcode,
        )
        .firstOrNull;
    if (match == null) return false;
    if (!await _outbox.discardIfPending(match.operationId)) return false;
    await _effects.rollback(match);
    return true;
  }

  /// Поставить операцию, применить её локальное следствие и попробовать отправить.
  ///
  /// Отправка идёт через движок синхронизации — тем же путём, которым уходит отложенная
  /// операция. Пока путей было два, отложенная отправка не применяла локальное следствие:
  /// привязка уезжала на сервер, а в карточке товара штрихкод не появлялся до следующей
  /// полной синхронизации справочников.
  ///
  /// Исход возвращается вызывающему как есть: экран решает сам, что показать.
  Future<Either<Failure, void>> _enqueueAndSend({
    required OutboxKind kind,
    required Map<String, dynamic> payload,
  }) async {
    final operationId = await _outbox.enqueue(kind: kind, payload: payload);
    await _effects.applyOptimistic(kind: kind, payload: payload);
    final operation = await _outbox.byOperationId(operationId);
    // Строки нет только если её успели убрать — тогда и отправлять нечего.
    if (operation == null) return const Right(null);
    return _sync.sendOne(operation);
  }

  /// Все группы номенклатуры (дерево фильтра).
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups() async {
    if (!await _ready(CatalogName.groups)) return _api.listGroups();
    return Right(await _cache.groups());
  }

  /// Поставщики (для фильтра), опционально по подстроке имени.
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query}) async {
    if (!await _ready(CatalogName.suppliers)) {
      return _api.listSuppliers(query: query);
    }
    return Right(await _cache.suppliers(query: query));
  }

  /// Список/поиск ячеек по адресу.
  Future<Either<Failure, Paged<Cell>>> listCells({
    String? query,
    String? warehouseId,
    int limit = 50,
    int offset = 0,
  }) async {
    if (!await _ready(CatalogName.cells)) {
      return _api.listCells(
        query: query,
        warehouseId: warehouseId,
        limit: limit,
        offset: offset,
      );
    }
    final all = await _cache.cells(query: query, warehouseId: warehouseId);
    final page = all.skip(offset).take(limit).toList();
    return Right(
      Paged<Cell>(items: page, total: all.length, limit: limit, offset: offset),
    );
  }

  /// Все ячейки склада разом (автокомплит ввода остатков).
  ///
  /// Раньше это были четыре запроса к серверу при каждом открытии экрана — и ещё раз после
  /// каждой завершённой ячейки. Теперь чтение из кэша; сигнатура не изменилась, поэтому
  /// вызывающий код тот же.
  Future<Either<Failure, List<Cell>>> listAllCells({
    String? warehouseId,
  }) async {
    if (!await _ready(CatalogName.cells)) {
      return _api.listAllCells(warehouseId: warehouseId);
    }
    return Right(await _cache.cells(warehouseId: warehouseId));
  }
}
