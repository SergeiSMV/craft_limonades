import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../../../core/sync/sync_engine.dart';
import '../domain/stock_entry_repository.dart';

/// Сессия ввода остатков по HTTP (P-FastStart): старт, checkpoint ячейки, финал. Слой data —
/// изолирует HTTP; access-токен подставит AuthInterceptor. Очередь операций отправляет
/// [SyncEngine] — тот же движок, что и у всего приложения.
@LazySingleton(as: StockEntryRepository)
class StockEntryRepositoryImpl implements StockEntryRepository {
  StockEntryRepositoryImpl(this._dio, this._engine);

  final Dio _dio;
  final SyncEngine _engine;

  @override
  Future<Either<Failure, String>> startSession(String warehouseId) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.stockEntrySessions,
        data: {'warehouse_id': warehouseId},
      );
      return Right(resp.data!['session_id'] as String);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  @override
  Future<Either<Failure, void>> checkpoint({
    required String sessionId,
    required Map<String, dynamic> body,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        ApiConst.stockEntryCells(sessionId),
        data: body,
      );
      return const Right(null);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  @override
  Future<Either<Failure, int>> finalize(String sessionId) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.stockEntryFinalize(sessionId),
      );
      return Right((resp.data?['written'] as num?)?.toInt() ?? 0);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  @override
  Future<bool> drainQueue() async => (await _engine.drain()).isDrained;
}
