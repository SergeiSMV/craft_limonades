import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/error/failure.dart';
import '../../features/stock/data/catalog_api.dart';
import '../../features/stock/domain/catalog_models.dart';
import '../domain/catalog/portal_catalog_repository.dart';

/// Справочники номенклатуры портала - напрямую с сервера через [CatalogApi] (ADHOC-71).
@LazySingleton(as: PortalCatalogRepository)
class PortalCatalogRepositoryImpl implements PortalCatalogRepository {
  PortalCatalogRepositoryImpl(this._api);

  final CatalogApi _api;

  @override
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) => _api.listGoods(
    query: query,
    groupId: groupId,
    supplierId: supplierId,
    limit: limit,
    offset: offset,
  );

  @override
  Future<Either<Failure, List<Barcode>>> listGoodBarcodes(String goodId) =>
      _api.listGoodBarcodes(goodId);

  @override
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups() =>
      _api.listGroups();

  @override
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query}) =>
      _api.listSuppliers(query: query);
}
