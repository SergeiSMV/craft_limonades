import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Документ «ввод остатков» (закрытая сессия) в разделе «Инвентаризация».
class StockEntryDoc {
  const StockEntryDoc({
    required this.id,
    required this.warehouseCode,
    required this.warehouseName,
    required this.closedAt,
    required this.linesCount,
  });

  final String id;
  final String warehouseCode;
  final String warehouseName;
  final DateTime closedAt;
  final int linesCount;

  factory StockEntryDoc.fromJson(Map<String, dynamic> j) => StockEntryDoc(
        id: j['id'] as String,
        warehouseCode: j['warehouse_code'] as String,
        warehouseName: j['warehouse_name'] as String,
        closedAt: DateTime.parse(j['closed_at'] as String),
        linesCount: (j['lines_count'] as num).toInt(),
      );
}

/// Репозиторий раздела «Инвентаризация»: список документов «ввод остатков» + скачивание .xlsx.
/// Слой data — изолирует HTTP; access-токен подставит AuthInterceptor. Всё admin-only на бэке.
@lazySingleton
class InventoryRepository {
  InventoryRepository(this._dio);

  final Dio _dio;

  /// Список документов «ввод остатков» (закрытые сессии), свежие сверху.
  Future<Either<Failure, List<StockEntryDoc>>> listDocuments() async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.stockEntrySessions);
      final items = (resp.data ?? const [])
          .map((e) => StockEntryDoc.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Скачать .xlsx-отчёт документа (байты).
  Future<Either<Failure, Uint8List>> downloadReport(String id) async {
    try {
      final resp = await _dio.get<List<int>>(
        ApiConst.stockEntryReport(id),
        options: Options(responseType: ResponseType.bytes),
      );
      return Right(Uint8List.fromList(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code != null) return Failure.server(code);
    return const Failure.network();
  }
}
