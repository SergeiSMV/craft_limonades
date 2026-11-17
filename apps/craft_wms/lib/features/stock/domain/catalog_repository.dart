import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import 'catalog_models.dart';

/// Справочники терминала и остатки - для экранов всех фич (P2-02).
///
/// Что: товары, группы, поставщики, ячейки и штрихкоды; привязка и отвязка ШК.
/// Зачем абстракция: экраны не знают, откуда данные - из кэша терминала или с сервера, и не
/// заводят своей логики «есть ли сеть». Чужие фичи берут каталог только через этот интерфейс
/// (`dev.md §2`, ADHOC-71), а не через `stock/data/`.
/// Как реализовано - `CatalogRepositoryImpl` в `data`: сначала кэш, сеть - там, где кэша
/// быть не может (до первой синхронизации, выдача внутреннего ШК); записи - через очередь.
abstract interface class CatalogRepository {
  /// Список/поиск товаров: «все слова присутствуют», фильтр по поддереву групп и поставщику.
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  });

  /// Товар по штрихкоду. `Right(null)` - ШК не привязан ни к одному товару (ответ сервера);
  /// `Left` - спросить не удалось, и привязан ШК или нет, неизвестно (ADHOC-06).
  Future<Either<Failure, Good?>> resolveGoodByBarcode(String code);

  /// Товар по идентификатору из справочника терминала; `null` - справочник не загружен или
  /// товара в нём нет.
  Future<Good?> goodById(String id);

  /// Товары по идентификаторам из справочника терминала одним запросом (ADHOC-59); пусто -
  /// справочник не загружен.
  Future<Map<String, Good>> goodsByIds(Iterable<String> ids);

  /// Штрихкоды товара. Пустой список - норма.
  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId);

  /// Привязать ШК к товару: операция в очередь, в кэше - сразу с пометкой «ожидает» (P2-06).
  /// [fromCzMark] - ШК взят из марки ЧЗ, товар заодно становится маркируемым (CZ-05).
  Future<Either<Failure, void>> bindBarcode({
    required String goodId,
    required String barcode,
    bool fromCzMark = false,
  });

  /// Выдать товару внутренний штрихкод (P4-07) - только по сети.
  Future<Either<Failure, IssuedBarcode>> issueInternalBarcode(String goodId);

  /// Ячейка приёмки по умолчанию (P4-09). `Right(null)` - справочник прочитан, а такой
  /// ячейки в нём нет.
  Future<Either<Failure, Cell?>> defaultCell();

  /// Отвязать ШК: операция в очередь, в кэше - сразу.
  Future<Either<Failure, void>> unbindBarcode({
    required String goodId,
    required String barcode,
  });

  /// Отменить привязку ШК, которая ещё не ушла на сервер (ADHOC-14). `false` - поздно:
  /// привязка уже на сервере или в пути.
  Future<bool> cancelPendingBind(String barcode);

  /// Все группы номенклатуры (дерево фильтра).
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups();

  /// Поставщики (для фильтра), опционально по подстроке имени.
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query});

  /// Список/поиск ячеек по адресу.
  Future<Either<Failure, Paged<Cell>>> listCells({
    String? query,
    String? warehouseId,
    int limit = 50,
    int offset = 0,
  });

  /// Все ячейки склада разом (автокомплит ввода остатков).
  Future<Either<Failure, List<Cell>>> listAllCells({String? warehouseId});

  /// Ячейка по идентификатору из справочника терминала, без сети; `null` - справочник не
  /// загружен или ячейки в нём нет. Нужна подписи места там, где ждать сервер на каждый скан
  /// незачем (адрес пика марки в сборке).
  Future<Cell?> cachedCellById(String id);
}
