import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/documents/documents_repository.dart';

/// Репозиторий документов оператора: рабочий список, скачивание .xlsx и отметка «Выполнено».
/// Общий для вкладок «Инвентаризация», «Приход» (P4-10) и «Движение» (P5-04) - они различаются только формой. Слой data - изолирует HTTP; access-токен подставит AuthInterceptor.
/// Всё admin-only на бэке.
@LazySingleton(as: DocumentsRepository)
class DocumentsRepositoryImpl implements DocumentsRepository {
  DocumentsRepositoryImpl(this._dio);

  final Dio _dio;

  /// Список документов одной формы ([kind]): необработанные сверху, выполненные - в конце.
  ///
  /// Форма фильтруется на сервере: без фильтра «Поступление» попадало бы во вкладку
  /// инвентаризации, и оператор искал бы свои документы среди чужих.
  @override
  Future<Either<Failure, List<PortalDoc>>> listDocuments({String? kind}) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        ApiConst.documents,
        queryParameters: kind == null ? null : {'kind': kind},
      );
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

  /// Скачать .xlsx документа: байты и имя файла. Сервер попутно отмечает документ скачанным.
  ///
  /// Имя берётся из `Content-Disposition`: его собирает сервер по форме документа
  /// («postuplenie-…», «dvizhenie-…»), и портал не должен знать формы, чтобы назвать файл
  /// правильно (ADHOC-24 - до этого имя было зашито под ввод остатков у всех форм).
  @override
  Future<Either<Failure, DownloadedDoc>> downloadReport(String id) async {
    try {
      final resp = await _dio.get<List<int>>(
        ApiConst.documentFile(id),
        options: Options(responseType: ResponseType.bytes),
      );
      return Right((
        bytes: Uint8List.fromList(resp.data!),
        filename: filenameFromDisposition(resp.headers.value('content-disposition')),
      ));
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Отметить документ занесённым в 1С. Идемпотентно: повтор сервер тоже принимает.
  @override
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

  /// История документа: сформирован → скачан → выполнен, с авторами.
  @override
  Future<Either<Failure, List<DocEvent>>> events(String id) async {
    try {
      final resp = await _dio.get<List<dynamic>>(ApiConst.documentEvents(id));
      final items = (resp.data ?? const [])
          .map((e) => DocEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      return Right(items);
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
