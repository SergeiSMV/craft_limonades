import 'dart:typed_data';

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

  /// Код склада для этикеток. На пилоте склад один — «Шабулина»/SHB (совпадает с дефолтом бэкенда).
  static const String _warehouse = 'SHB';

  /// Скачивание PDF-этикеток ячеек: `GET /cells/labels.pdf?warehouse=SHB` (ответ — bytes).
  /// Что: получаем готовый PDF (штрихкоды + адреса ячеек) байтами.
  /// Зачем: оператор печатает этикетки и клеит на ячейки (идентификация ячейки сканом).
  /// Как: `responseType: bytes` (тело не JSON); admin-only — токен подставит AuthInterceptor,
  ///      403/404 приедут как ServerFailure. Скачивание файла в браузере — на стороне UI.
  Future<Either<Failure, Uint8List>> downloadCellLabels() async {
    try {
      final resp = await _dio.get<List<int>>(
        ApiConst.cellLabelsPdf,
        queryParameters: {'warehouse': _warehouse},
        options: Options(responseType: ResponseType.bytes),
      );
      return Right(Uint8List.fromList(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

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
