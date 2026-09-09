import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Состояние документа в работе оператора (P3-02).
/// Порядок значений — порядок жизни документа: опубликован → скачан → занесён в 1С.
enum DocStatus {
  /// Опубликован, оператор его ещё не брал.
  isNew,

  /// Файл скачан, но в 1С ещё не отмечен.
  downloaded,

  /// Занесён в 1С — работа по документу закончена.
  done;

  /// Разбор значения с сервера. Незнакомое трактуем как «новый»: документ лучше показать
  /// требующим внимания, чем спрятать в выполненных из-за расхождения версий.
  static DocStatus parse(String? raw) => switch (raw) {
        'downloaded' => DocStatus.downloaded,
        'done' => DocStatus.done,
        _ => DocStatus.isNew,
      };
}

/// Документ оператора: что сформировано, по какому складу и в каком состоянии.
class PortalDoc {
  const PortalDoc({
    required this.id,
    required this.warehouseCode,
    required this.warehouseName,
    required this.createdAt,
    required this.linesCount,
    required this.status,
  });

  final String id;
  final String warehouseCode;
  final String warehouseName;
  final DateTime createdAt;
  final int linesCount;
  final DocStatus status;

  factory PortalDoc.fromJson(Map<String, dynamic> j) => PortalDoc(
        id: j['id'] as String,
        warehouseCode: j['warehouse_code'] as String? ?? '',
        warehouseName: j['warehouse_name'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        linesCount: (j['lines_count'] as num?)?.toInt() ?? 0,
        status: DocStatus.parse(j['status'] as String?),
      );
}

/// Репозиторий раздела «Инвентаризация»: рабочий список документов, скачивание .xlsx
/// и отметка «Выполнено». Слой data — изолирует HTTP; access-токен подставит AuthInterceptor.
/// Всё admin-only на бэке.
@lazySingleton
class InventoryRepository {
  InventoryRepository(this._dio);

  final Dio _dio;

  /// Список документов: необработанные сверху, выполненные — в конце.
  Future<Either<Failure, List<PortalDoc>>> listDocuments() async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.documents);
      final items = (resp.data ?? const [])
          .map((e) => PortalDoc.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Скачать .xlsx документа (байты). Сервер попутно отмечает документ скачанным.
  Future<Either<Failure, Uint8List>> downloadReport(String id) async {
    try {
      final resp = await _dio.get<List<int>>(
        ApiConst.documentFile(id),
        options: Options(responseType: ResponseType.bytes),
      );
      return Right(Uint8List.fromList(resp.data!));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Отметить документ занесённым в 1С. Идемпотентно: повтор сервер тоже принимает.
  Future<Either<Failure, void>> markDone(String id) async {
    try {
      await _dio.post<void>(ApiConst.documentDone(id));
      return const Right(null);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Маппинг ошибки dio в доменную Failure: есть код ответа → серверная, иначе → сетевая.
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code != null) return Failure.server(code);
    return const Failure.network();
  }
}
