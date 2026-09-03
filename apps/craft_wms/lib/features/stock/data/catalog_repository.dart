import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
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
  CatalogRepository(this._api, this._cache);

  final CatalogApi _api;
  final CatalogCache _cache;

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

  /// Штрихкоды товара (секция «Штрихкоды» карточки). Пустой список — норма.
  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId) async {
    if (!await _ready(CatalogName.barcodes)) {
      return _api.listGoodBarcodes(goodId);
    }
    return Right(await _cache.barcodesOfGood(goodId));
  }

  /// Привязать ШК к товару. Пишется на сервер; кэш обновляется точечно, чтобы повторный скан
  /// узнавался сразу, не дожидаясь следующей синхронизации.
  Future<Either<Failure, void>> bindBarcode({
    required String goodId,
    required String barcode,
  }) async {
    final res = await _api.bindBarcode(goodId: goodId, barcode: barcode);
    if (res.isRight) await _cache.addBarcode(barcode: barcode, goodId: goodId);
    return res;
  }

  /// Отвязать ШК. Как и привязка — сначала сервер, затем точечная правка кэша.
  Future<Either<Failure, void>> unbindBarcode(String code) async {
    final res = await _api.unbindBarcode(code);
    if (res.isRight) await _cache.removeBarcode(code);
    return res;
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

  /// Остатки товара по ячейкам и партиям — **всегда сеть**.
  ///
  /// Остаток меняется от каждой операции любого терминала. Показать кладовщику число, которое
  /// уже неверно, хуже честного «нет связи»: по неверному он примет решение (решение
  /// пользователя, P2-02).
  Future<Either<Failure, Paged<StockItem>>> listStock({
    String? goodId,
    String? cellId,
    int limit = 200,
    int offset = 0,
  }) => _api.listStock(
    goodId: goodId,
    cellId: cellId,
    limit: limit,
    offset: offset,
  );
}
