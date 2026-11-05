import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/cells/cell_setup.dart';
import 'import_report.dart';

/// Репозиторий страницы «Ячейки» портала (ADHOC-57): список ячеек и стеллажей, массовая
/// правка галочек этикеток, загрузка и выгрузка `.xlsx` в формате rack_labels, печать PDF.
/// Слой data: изолирует HTTP от UI, отдаёт `Either<Failure, T>`.
@lazySingleton
class CellsRepository {
  CellsRepository(this._dio);

  final Dio _dio;

  /// Код склада. На пилоте склад один — «Шабулина»/SHB (совпадает с дефолтом бэкенда).
  static const String warehouse = 'SHB';

  static const _query = {'warehouse': warehouse};

  /// Все ячейки склада (без ячейки приёмки) и его стеллажи: `GET /cells/setup`.
  Future<Either<Failure, CellsSetup>> loadSetup() => _guard(() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      ApiConst.cellsSetup,
      queryParameters: _query,
    );
    return _parseSetup(resp.data!);
  });

  /// Массовая правка галочек: `PATCH /cells/setup`. В теле — только изменённые галочки;
  /// «на карточке» сервер ставит только ячейкам со стеллажом. Всё или ничего: 409 — среди
  /// ячеек есть чужие, ничего не изменено. Ответ — сколько ячеек изменено.
  Future<Either<Failure, int>> saveSettings(
    List<String> cellIds,
    Map<CellFlag, bool> changes,
  ) => _guard(() async {
    final resp = await _dio.patch<Map<String, dynamic>>(
      ApiConst.cellsSetup,
      queryParameters: _query,
      data: {
        'cell_ids': cellIds,
        for (final MapEntry(:key, :value) in changes.entries)
          _flagField(key): value,
      },
    );
    return (resp.data?['cells_updated'] as num?)?.toInt() ?? 0;
  });

  /// Выгрузка всего склада `.xlsx` в формате rack_labels: `GET /cells/export.xlsx`.
  Future<Either<Failure, Uint8List>> exportCells() => _guard(() async {
    final resp = await _dio.get<List<int>>(
      ApiConst.cellsExport,
      queryParameters: _query,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data!);
  });

  /// PDF одного вида: `POST /cells/labels.pdf`. Пустой [cellIds] — весь склад. 409 — чужие
  /// ячейки; 422 — печатать нечего или не влезает (причины — в тексте ошибки).
  Future<Either<Failure, Uint8List>> labelsPdf(
    LabelKind kind,
    List<String> cellIds,
  ) => _guard(() async {
    final resp = await _dio.post<List<int>>(
      ApiConst.cellLabelsPdf,
      queryParameters: _query,
      data: {'kind': kind.code, 'cell_ids': cellIds},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data!);
  });

  /// Загрузка `.xlsx` в формате rack_labels: `POST /import/cells` (multipart, поле `file`).
  /// На вебе файла на диске нет — шлём байты из выбора файла браузера.
  Future<Either<Failure, CellsImportReport>> importCells({
    required List<int> bytes,
    required String filename,
  }) => _guard(() async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final resp = await _dio.post<Map<String, dynamic>>(
      ApiConst.importCells,
      data: form,
    );
    return CellsImportReport.fromJson(resp.data!);
  });

  static String _flagField(CellFlag f) => switch (f) {
    CellFlag.small => 'label_small',
    CellFlag.floor => 'is_floor',
    CellFlag.barcode => 'label_barcode',
    CellFlag.sideCard => 'side_card',
  };

  static CellsSetup _parseSetup(Map<String, dynamic> d) => CellsSetup(
    warehouse: d['warehouse'] as String? ?? warehouse,
    cells: [
      for (final c
          in (d['cells'] as List? ?? const []).cast<Map<String, dynamic>>())
        CellSetup(
          id: c['id'] as String,
          address: c['address'] as String,
          rackId: c['rack_id'] as String?,
          rackCode: c['rack_code'] as String?,
          isFloor: c['is_floor'] as bool? ?? false,
          labelSmall: c['label_small'] as bool? ?? false,
          labelBarcode: c['label_barcode'] as bool? ?? false,
          sideCard: c['side_card'] as bool? ?? false,
        ),
    ],
    racks: [
      for (final r
          in (d['racks'] as List? ?? const []).cast<Map<String, dynamic>>())
        Rack(id: r['id'] as String, code: r['code'] as String),
    ],
  );

  /// Запрос с переводом ошибок dio в доменные [Failure].
  Future<Either<Failure, T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Right(await call());
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Ответ сервера с кодом — [ServerFailure] с текстом ошибки (`{"error": "…"}`): его
  /// показываем как есть — причины 409 и 422 оператору нужны дословно. У запросов файла тело
  /// ошибки приходит байтами — разбираем его тоже.
  static Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == null) return const Failure.network();
    return Failure.server(code, _errorText(e.response?.data));
  }

  static String? _errorText(Object? data) {
    Object? body = data;
    if (data is List<int>) {
      try {
        body = jsonDecode(utf8.decode(data));
      } catch (_) {
        return null;
      }
    }
    return body is Map ? body['error'] as String? : null;
  }
}
