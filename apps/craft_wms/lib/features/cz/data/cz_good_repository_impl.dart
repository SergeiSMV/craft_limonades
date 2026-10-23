import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../../stock/data/catalog_cache.dart';
import '../domain/cz_good_repository.dart';

/// Правка признака «маркируемый» (CZ-05): `PATCH goods/{id}/cz-marked`, затем кэш товаров.
///
/// Кэш — после ответа сервера, а не до: правка онлайн, и пометка в кэше без подтверждения
/// разошлась бы со справочником до следующей загрузки.
@LazySingleton(as: CzGoodRepository)
class CzGoodRepositoryImpl implements CzGoodRepository {
  CzGoodRepositoryImpl(this._dio, this._cache);

  final Dio _dio;
  final CatalogCache _cache;

  @override
  Future<Either<Failure, void>> setCzMarked({
    required String goodId,
    required bool marked,
  }) async {
    try {
      await _dio.patch<Map<String, dynamic>>(
        ApiConst.goodCzMarked(goodId),
        data: {'cz_marked': marked},
      );
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
    await _cache.setGoodCzMarked(goodId, marked);
    return const Right(null);
  }
}
