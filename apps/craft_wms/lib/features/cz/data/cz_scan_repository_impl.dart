import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/cz_scan.dart';
import 'cz_scan_dto.dart';

/// Скан «Честного знака» через сервер (CZ-04): `POST cz/scan {code}`.
///
/// Только онлайн и без кэша: данные ЧЗ живые (статус марки меняется вне склада), а без связи
/// True API недоступен и серверу. Обрыв - `Failure.network`, экран говорит «нужна связь».
@LazySingleton(as: CzScanRepository)
class CzScanRepositoryImpl implements CzScanRepository {
  CzScanRepositoryImpl(this._dio);

  final Dio _dio;

  /// Предел ожидания ответа: по коробу сервер делает несколько запросов в ЧЗ подряд (короб,
  /// его вложенные, упаковки), поэтому дольше обычного экрана.
  static const _timeout = Duration(seconds: 30);

  @override
  Future<Either<Failure, CzScanResult>> scan(String code) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.czScan,
        data: {'code': code},
        options: Options(receiveTimeout: _timeout),
      );
      final data = resp.data;
      if (data == null) return const Left(Failure.unknown());
      return Right(czScanFromJson(data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  @override
  Future<Either<Failure, List<CzScanBatchItem>>> scanMany(
    List<String> codes,
  ) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.czScanBatch,
        data: {'codes': codes},
        options: Options(receiveTimeout: _timeout),
      );
      final data = resp.data;
      if (data == null) return const Left(Failure.unknown());
      return Right(czScanBatchFromJson(data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
