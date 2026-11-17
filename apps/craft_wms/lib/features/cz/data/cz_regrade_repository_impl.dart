import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../../stock/data/catalog_cache.dart';
import '../domain/cz_regrade_repository.dart';

/// Перепривязка ШК с пересортом (ADHOC-53): `GET barcodes/{code}/cz-stock`,
/// `POST barcodes/{code}/regrade`, затем кэш справочника.
///
/// Кэш - после ответа сервера: перепривязка онлайн, и правка привязки до подтверждения
/// разошлась бы со справочником.
@LazySingleton(as: CzRegradeRepository)
class CzRegradeRepositoryImpl implements CzRegradeRepository {
  CzRegradeRepositoryImpl(this._dio, this._cache);

  final Dio _dio;
  final CatalogCache _cache;

  @override
  Future<Either<Failure, int>> marksInStock(String barcode) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        ApiConst.barcodeCzStock(barcode),
      );
      return Right((res.data?['marks_in_stock'] as num?)?.toInt() ?? 0);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  @override
  Future<Either<Failure, int>> regrade({
    required String barcode,
    required String goodId,
  }) async {
    final int marks;
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        ApiConst.barcodeRegrade(barcode),
        data: {'good_id': goodId},
      );
      marks = (res.data?['marks'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
    // Привязка заменяется на месте; новый товар - маркируемый, как его пометил сервер.
    await _cache.addBarcode(barcode: barcode, goodId: goodId);
    await _cache.setGoodCzMarked(goodId, true);
    return Right(marks);
  }
}
