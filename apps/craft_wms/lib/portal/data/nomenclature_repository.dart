import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import 'import_report.dart';

/// Репозиторий импорта справочников через веб-портал.
/// Слой data: изолирует HTTP от UI, отдаёт `Either<Failure, ImportReport>`.
@lazySingleton
class NomenclatureRepository {
  NomenclatureRepository(this._dio);

  final Dio _dio;

  /// Загрузка `.xls`-выгрузки номенклатуры: `POST /import/goods` (multipart, поле `file`).
  /// Что: шлём байты выбранного файла на бэкенд, получаем отчёт created/updated/skipped.
  /// Зачем: на вебе файла на диске нет - работаем с байтами из file_picker (`withData`).
  /// Как: MultipartFile.fromBytes с именем файла (бэкенд читает поле `file`); admin-only -
  ///      access подставит AuthInterceptor, 403 для не-admin приедет как ServerFailure.
  Future<Either<Failure, ImportReport>> importGoods({
    required List<int> bytes,
    required String filename,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final resp = await _dio.post<Map<String, dynamic>>(ApiConst.importGoods, data: form);
      return Right(ImportReport.fromJson(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Маппинг ошибок dio в доменные Failure. 422 - проблема с файлом (нет колонки/не читается),
  /// её текст с бэкенда полезно показать; остальное - обобщаем.
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
