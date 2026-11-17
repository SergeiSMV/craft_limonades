import 'dart:typed_data';

import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Состояние документа в работе оператора (P3-02).
/// Порядок значений - порядок жизни документа: опубликован → скачан → занесён в 1С.
enum DocStatus {
  /// Опубликован, оператор его ещё не брал.
  isNew,

  /// Файл скачан, но в 1С ещё не отмечен.
  downloaded,

  /// Занесён в 1С - работа по документу закончена.
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

  /// Причина ошибки - только у `generation_failed`.
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
    this.number = 0,
    this.sourceNumber = 0,
    this.stocktakeNumber = 0,
    this.executor = '',
    required this.warehouseCode,
    required this.warehouseName,
    required this.createdAt,
    required this.linesCount,
    required this.status,
  });

  final String id;

  /// Форма документа: `stock_entry` - ввод остатков, `receipt` - «Поступление» (P4-10),
  /// `movement` - «Движение» (P5-04).
  final String kind;

  /// Поставщик: у «Поступления» - свой, у «Движения» размещения - приёмки-основания;
  /// пусто - без поставщика.
  final String supplier;

  /// Документ поставщика (ADHOC-23): номер и дата DD-MM-YYYY; пусто - нет. У «Движения»
  /// размещения - накладная приёмки-основания.
  final String docNumber;
  final String docDate;

  /// Операция «Движения» (`putaway` - размещение, `move` - перемещение); пусто - другая
  /// форма.
  final String operation;

  /// Номер задания-основания «Движения»; 0 - нет (перемещение идёт без задания).
  final int taskNumber;

  /// Проблема склада, решение «разместить» по которой завело задание (ADHOC-55); 0 - задание
  /// из приёмки или его нет.
  final int problemNumber;

  /// Номер документа - счётчик своей формы (ADHOC-55).
  final int number;

  /// Номер операции-источника (ADHOC-55): приёмки, сеанса размещения, перемещения или
  /// пополнения, ввода остатков; у «Инвентаризации» - номер пересчёта. 0 - нет.
  final int sourceNumber;

  /// Пересчёт «Инвентаризации» (P10-05); 0 - другая форма.
  final int stocktakeNumber;

  /// Кто выполнил операцию - ФИО из документа; пусто - неизвестно.
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
    number: (j['number'] as num?)?.toInt() ?? 0,
    sourceNumber: (j['source_number'] as num?)?.toInt() ?? 0,
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

/// Имя файла по умолчанию - если сервер его не прислал.
const kDefaultDocFilename = 'document.xlsx';

/// Имя файла из заголовка `Content-Disposition` (`attachment; filename="…"`).
///
/// Сервер шлёт имя латиницей в простой форме `filename=`, поэтому `filename*` с кодировкой
/// не разбираем. Заголовка или имени нет - [kDefaultDocFilename]: файл важнее имени.
String filenameFromDisposition(String? header) {
  if (header == null) return kDefaultDocFilename;
  final match = RegExp(r'filename="?([^";]+)"?').firstMatch(header);
  final name = match?.group(1)?.trim() ?? '';
  return name.isEmpty ? kDefaultDocFilename : name;
}

/// Репозиторий документов оператора: рабочий список, скачивание .xlsx и отметка «Выполнено».
/// Общий для вкладок «Инвентаризация», «Приход» (P4-10) и «Движение» (P5-04) - они
/// различаются только формой.
/// Всё admin-only на бэке.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `DocumentsRepositoryImpl` в `data`.
abstract interface class DocumentsRepository {
  /// Список документов одной формы ([kind]): необработанные сверху, выполненные - в конце.
  ///
  /// Форма фильтруется на сервере: без фильтра «Поступление» попадало бы во вкладку
  /// инвентаризации, и оператор искал бы свои документы среди чужих.
  Future<Either<Failure, List<PortalDoc>>> listDocuments({String? kind});

  /// Скачать .xlsx документа: байты и имя файла. Сервер попутно отмечает документ скачанным.
  ///
  /// Имя берётся из `Content-Disposition`: его собирает сервер по форме документа
  /// («postuplenie-…», «dvizhenie-…»), и портал не должен знать формы, чтобы назвать файл
  /// правильно (ADHOC-24 - до этого имя было зашито под ввод остатков у всех форм).
  Future<Either<Failure, DownloadedDoc>> downloadReport(String id);

  /// Отметить документ занесённым в 1С. Идемпотентно: повтор сервер тоже принимает.
  Future<Either<Failure, void>> markDone(String id);

  /// История документа: сформирован → скачан → выполнен, с авторами.
  Future<Either<Failure, List<DocEvent>>> events(String id);
}
