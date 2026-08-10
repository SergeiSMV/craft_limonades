import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import 'import_report.dart';

/// Репозиторий импорта ячеек склада через веб-портал.
/// Слой data: изолирует HTTP от UI, отдаёт `Either<Failure, CellsImportReport>`.
@lazySingleton
class CellsRepository {
  CellsRepository(this._dio);

  final Dio _dio;

  /// Загрузка `.xlsx`-файла ячеек: `POST /import/cells` (multipart, поле `file`).
  /// Что: шлём байты выбранного файла, получаем отчёт created/updated/skipped.
  /// Зачем: на вебе файла на диске нет — работаем с байтами из file_picker (`withData`).
  /// Как: MultipartFile.fromBytes с именем файла; admin-only — access подставит AuthInterceptor,
  ///      403 для не-admin приедет как ServerFailure. Склад — дефолт бэкенда («Шабулина»/SHB).
  Future<Either<Failure, CellsImportReport>> importCells({
    required List<int> bytes,
    required String filename,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final resp = await _dio.post<Map<String, dynamic>>(ApiConst.importCells, data: form);
      return Right(CellsImportReport.fromJson(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Маппинг ошибок dio в доменные Failure. 422 — проблема с файлом (нет колонки/не читается),
  /// её текст с бэкенда полезно показать; остальное — обобщаем.
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 422) {
      final msg = (e.response?.data is Map) ? (e.response!.data['error'] as String?) : null;
      return Failure.server(422, msg);
    }
    if (code != null) {
      return Failure.server(code);
    }
    return const Failure.network();
  }
}
