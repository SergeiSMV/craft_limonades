import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';
import '../../../features/stock/domain/catalog_models.dart';

/// Справочники номенклатуры для портала: товары, группы, поставщики, штрихкоды товара.
///
/// Зачем отдельно от `CatalogRepository` ТСД: портал читает сервер напрямую, без кэша
/// терминала (вкладки «Номенклатура» и «Остатки», карточка товара). Раньше экраны портала
/// держали `CatalogApi` из `stock/data/`; интерфейс закрывает это по `dev.md §2` (ADHOC-71).
/// Реализация - `PortalCatalogRepositoryImpl` в `data`, поверх того же `CatalogApi`.
abstract interface class PortalCatalogRepository {
  /// Список/поиск товаров: «все слова присутствуют», фильтр по поддереву групп и поставщику.
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  });

  /// Штрихкоды товара. Пустой список - норма.
  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId);

  /// Все группы номенклатуры (дерево фильтра).
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups();

  /// Поставщики (для фильтра), опционально по подстроке имени.
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query});
}
