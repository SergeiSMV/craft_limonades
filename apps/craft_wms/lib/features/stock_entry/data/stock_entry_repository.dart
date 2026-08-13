import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/failure.dart';
import '../../stock/data/catalog_models.dart';

/// Репозиторий сессии ввода остатков (P-FastStart): резолв товара по ШК, старт сессии,
/// checkpoint ячейки, финал. Слой data — изолирует HTTP; access-токен подставит AuthInterceptor.
@lazySingleton
class StockEntryRepository {
  StockEntryRepository(this._dio);

  final Dio _dio;

  /// Товар по штрихкоду. Нет привязки (404) → `Right(null)` — это штатный сигнал «нужна привязка»,
  /// а не ошибка. Прочие ошибки → `Left(Failure)`.
  Future<Either<Failure, Good?>> resolveGoodByBarcode(String code) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(ApiConst.barcodeByCode(code));
      return Right(Good.fromJson(resp.data!));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return const Right(null);
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Открыть сессию ввода для склада; возвращает её id.
  Future<Either<Failure, String>> startSession(String warehouseId) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.stockEntrySessions,
        data: {'warehouse_id': warehouseId},
      );
      return Right(resp.data!['session_id'] as String);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Checkpoint ячейки: строки + новые привязки ШК (коммитятся одной транзакцией на бэке).
  /// [lines] — `[{good_id, production_date(DD-MM-YYYY), qty}]`; [newBarcodes] — `[{good_id, barcode, symbology}]`.
  Future<Either<Failure, void>> checkpoint({
    required String sessionId,
    required String cellId,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> newBarcodes,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        ApiConst.stockEntryCells(sessionId),
        data: {'cell_id': cellId, 'lines': lines, 'new_barcodes': newBarcodes},
      );
      return const Right(null);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Финал сессии: перенос всех строк в stock + закрытие. Возвращает число записанных строк.
  Future<Either<Failure, int>> finalize(String sessionId) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(ApiConst.stockEntryFinalize(sessionId));
      return Right((resp.data?['written'] as num?)?.toInt() ?? 0);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Маппинг ошибок dio в доменные Failure (что показать — решает cubit).
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401) return const Failure.auth();
    if (code != null) {
      final msg = (e.response?.data is Map) ? (e.response!.data['error'] as String?) : null;
      return Failure.server(code, msg);
    }
    return const Failure.network();
  }
}
