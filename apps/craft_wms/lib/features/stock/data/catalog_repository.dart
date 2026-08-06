import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/failure.dart';
import 'catalog_models.dart';

/// Репозиторий чтения справочников: ходит на `/goods`, `/nomenclature-groups`,
/// `/suppliers`, `/stock` (API P1-06) и возвращает `Either<Failure, T>`.
/// Слой data — изолирует сеть от домена/UI; access-токен подставит AuthInterceptor.
@lazySingleton
class CatalogRepository {
  CatalogRepository(this._dio);

  final Dio _dio;

  /// Список/поиск товаров с пагинацией и фильтрами. Пустые фильтры не шлём (nil = без фильтра).
  Future<Either<Failure, Paged<Good>>> listGoods({
    String? query,
    String? groupId,
    String? supplierId,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.goods,
        queryParameters: _compact({
          'q': query,
          'group_id': groupId,
          'supplier_id': supplierId,
          'limit': limit,
          'offset': offset,
        }),
      );
      return Right(Paged.fromJson(resp.data!, Good.fromJson));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Все группы номенклатуры (клиент строит дерево / список фильтра).
  Future<Either<Failure, List<NomenclatureGroup>>> listGroups() async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.nomenclatureGroups);
      final items = (resp.data ?? const [])
          .map((e) => NomenclatureGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Поставщики (для фильтра). Опциональный поиск по подстроке имени.
  Future<Either<Failure, List<Supplier>>> listSuppliers({String? query}) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        ApiConst.suppliers,
        queryParameters: _compact({'q': query}),
      );
      final items = (resp.data ?? const [])
          .map((e) => Supplier.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Остатки товара в разрезе ячеек/партий (карточка «где лежит товар X»).
  Future<Either<Failure, Paged<StockItem>>> listStock({
    String? goodId,
    String? cellId,
    int limit = 200,
    int offset = 0,
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        ApiConst.stock,
        queryParameters: _compact({
          'good_id': goodId,
          'cell_id': cellId,
          'limit': limit,
          'offset': offset,
        }),
      );
      return Right(Paged.fromJson(resp.data!, StockItem.fromJson));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Выкидывает null-значения из query — чтобы пустые фильтры не уходили в URL.
  Map<String, dynamic> _compact(Map<String, dynamic> params) {
    params.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
    return params;
  }

  /// Маппинг ошибок dio в доменные Failure (что показать — решает cubit).
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) {
      return const Failure.auth();
    }
    if (code != null) {
      return Failure.server(code);
    }
    return const Failure.network();
  }
}
