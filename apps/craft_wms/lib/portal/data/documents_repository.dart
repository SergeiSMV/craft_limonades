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

/// Запись журнала документа (P3-03): что произошло, когда и по чьей воле.
class DocEvent {
  const DocEvent({
    required this.event,
    required this.userName,
    required this.details,
    required this.createdAt,
  });

  /// `created` · `downloaded` · `done` · `generation_failed`.
  final String event;

  /// Пусто, если событие системное или автор не сохранился (события до появления журнала).
  final String userName;

  /// Причина ошибки — только у `generation_failed`.
  final String details;

  final DateTime createdAt;

  factory DocEvent.fromJson(Map<String, dynamic> j) => DocEvent(
        event: j['event'] as String? ?? '',
        userName: j['user_name'] as String? ?? '',
        details: j['details'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

/// Документ оператора: что сформировано, по какому складу и в каком состоянии.
class PortalDoc {
  const PortalDoc({
    required this.id,
    required this.kind,
    this.supplier = '',
    this.docNumber = '',
    this.docDate = '',
    this.operation = '',
    this.taskNumber = 0,
    this.problemNumber = 0,
    this.stocktakeNumber = 0,
    this.executor = '',
    required this.warehouseCode,
    required this.warehouseName,
    required this.createdAt,
    required this.linesCount,
    required this.status,
  });

  final String id;

  /// Форма документа: `stock_entry` — ввод остатков, `receipt` — «Поступление» (P4-10),
  /// `movement` — «Движение» (P5-04).
  final String kind;

  /// Поставщик: у «Поступления» — свой, у «Движения» размещения — приёмки-основания;
  /// пусто — без поставщика.
  final String supplier;

  /// Документ поставщика (ADHOC-23): номер и дата DD-MM-YYYY; пусто — нет. У «Движения»
  /// размещения — накладная приёмки-основания.
  final String docNumber;
  final String docDate;

  /// Операция «Движения» (`putaway` — размещение, `move` — перемещение); пусто — другая
  /// форма.
  final String operation;

  /// Номер задания-основания «Движения»; 0 — нет (перемещение идёт без задания).
  final int taskNumber;

  /// Проблема склада, решение «разместить» по которой завело задание (ADHOC-55); 0 — задание
  /// из приёмки или его нет.
  final int problemNumber;

  /// Пересчёт «Инвентаризации» (P10-05); 0 — другая форма.
  final int stocktakeNumber;

  /// Кто выполнил операцию — ФИО из документа; пусто — неизвестно.
  final String executor;
  final String warehouseCode;
  final String warehouseName;
  final DateTime createdAt;
  final int linesCount;
  final DocStatus status;

  factory PortalDoc.fromJson(Map<String, dynamic> j) => PortalDoc(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? '',
        supplier: j['supplier'] as String? ?? '',
        docNumber: j['doc_number'] as String? ?? '',
        docDate: j['doc_date'] as String? ?? '',
        operation: j['operation'] as String? ?? '',
        taskNumber: (j['task_number'] as num?)?.toInt() ?? 0,
        problemNumber: (j['problem_number'] as num?)?.toInt() ?? 0,
        stocktakeNumber: (j['stocktake_number'] as num?)?.toInt() ?? 0,
        executor: j['executor'] as String? ?? '',
        warehouseCode: j['warehouse_code'] as String? ?? '',
        warehouseName: j['warehouse_name'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        linesCount: (j['lines_count'] as num?)?.toInt() ?? 0,
        status: DocStatus.parse(j['status'] as String?),
      );
}

/// Скачанный документ: содержимое и имя файла, под которым его сохранить.
typedef DownloadedDoc = ({Uint8List bytes, String filename});

/// Имя файла по умолчанию — если сервер его не прислал.
const kDefaultDocFilename = 'document.xlsx';

/// Имя файла из заголовка `Content-Disposition` (`attachment; filename="…"`).
///
/// Сервер шлёт имя латиницей в простой форме `filename=`, поэтому `filename*` с кодировкой
/// не разбираем. Заголовка или имени нет — [kDefaultDocFilename]: файл важнее имени.
String filenameFromDisposition(String? header) {
  if (header == null) return kDefaultDocFilename;
  final match = RegExp(r'filename="?([^";]+)"?').firstMatch(header);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? kDefaultDocFilename : name;
}

/// Репозиторий документов оператора: рабочий список, скачивание .xlsx и отметка «Выполнено».
/// Общий для вкладок «Инвентаризация», «Приход» (P4-10) и «Движение» (P5-04) — они различаются только формой. Слой data — изолирует HTTP; access-токен подставит AuthInterceptor.
/// Всё admin-only на бэке.
@lazySingleton
class DocumentsRepository {
  DocumentsRepository(this._dio);

  final Dio _dio;

  /// Список документов одной формы ([kind]): необработанные сверху, выполненные — в конце.
  ///
  /// Форма фильтруется на сервере: без фильтра «Поступление» попадало бы во вкладку
  /// инвентаризации, и оператор искал бы свои документы среди чужих.
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
  /// правильно (ADHOC-24 — до этого имя было зашито под ввод остатков у всех форм).
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
