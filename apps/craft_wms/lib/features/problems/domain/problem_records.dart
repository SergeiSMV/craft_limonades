import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Проблемы склада списком на ТСД: вкладки «Текущие» (ADHOC-35) и «Завершённые» (ADHOC-34)
/// в «Проблемах склада».
///
/// Кладовщик видит проблемы всего склада, не только свои: что ещё ждёт решения офиса и что
/// офис решил — списано по документу 1С, размещено обратно в «Основной», уехало поставщику.
/// Списки — с сервера; свои неотправленные проблемы «Текущие» берут из очереди терминала.

/// Решение офиса — как значение приходит с сервера.
abstract final class ProblemDecision {
  /// Списано по документу 1С.
  static const writeOff = 'write_off';

  /// Метка снята — товар снова в «Основном» на том же месте.
  static const place = 'place';

  /// Возврат поставщику: товар на складе возврата и в задании на отгрузку.
  static const supplierReturn = 'supplier_return';

  /// Пересорт проведён документом пересортицы 1С (ADHOC-53).
  static const regrade = 'regrade';
}

/// Товар проблемы: у открытой — что помечено сейчас (состав короба или товар), у решённой —
/// что решение фактически взяло; товар, партия, количество, ячейка.
class ProblemRecordItem {
  const ProblemRecordItem({
    required this.goodName,
    this.goodCode,
    required this.productionDate,
    required this.qty,
    required this.cellAddress,
  });

  final String goodName;
  final String? goodCode;

  /// Дата партии, YYYY-MM-DD — как отдаёт сервер.
  final String productionDate;

  /// Количество строкой сервера («2.000»).
  final String qty;
  final String cellAddress;
}

/// Проблема склада: что и где помечено, кем и когда; у решённой — что решил офис и кто
/// исполнил.
class ProblemRecord {
  const ProblemRecord({
    required this.id,
    this.number,
    required this.createdAt,
    required this.createdBy,
    required this.cellAddress,
    this.loadUnitId,
    required this.reason,
    this.comment = '',
    this.mark,
    required this.fromWarehouse,
    required this.toWarehouse,
    this.items = const [],
    this.decision = '',
    this.docNumber,
    this.docDate,
    this.supplierName,
    this.returnTaskNumber,
    this.resolvedBy = '',
    this.resolvedAt,
    this.shippedBy,
    this.shippedAt,
    this.pending = false,
    this.photos = const [],
  });

  final String id;

  /// Номер проблемы (ADHOC-55); `null` у своей неотправленной — номер выдаёт сервер.
  final int? number;
  final DateTime createdAt;

  /// Кто зафиксировал; пусто у своей неотправленной — её зафиксировали на этом терминале.
  final String createdBy;

  /// Где помечено; пусто — ячейка неизвестна (свой короб, которого нет в снимке).
  final String cellAddress;

  /// Короб целиком; `null` — товар.
  final String? loadUnitId;

  /// Причина — значение сервера (`breakage`, …).
  final String reason;
  final String comment;

  /// Марка ЧЗ — у «не нашей марки».
  final String? mark;
  final String fromWarehouse;
  final String toWarehouse;

  /// Фото на сервере — идентификаторы в порядке съёмки (ADHOC-45).
  final List<String> photos;

  final List<ProblemRecordItem> items;

  /// Решение — [ProblemDecision]; пусто — проблема открыта.
  final String decision;

  /// Документ списания 1С: номер и дата YYYY-MM-DD.
  final String? docNumber;
  final String? docDate;

  /// Возврат: кому и номер задания на отгрузку.
  final String? supplierName;
  final int? returnTaskNumber;

  /// Кто решил в портале; пусто — открыта.
  final String resolvedBy;

  /// Момент решения строкой, как его отдал сервер: это и курсор подгрузки, и сервер ждёт его
  /// до наносекунд — перевод в DateTime и обратно их терял бы. `null` — открыта.
  final String? resolvedAt;

  /// Кто и когда отгрузил возврат поставщику на ТСД; `null` — ещё не отгружен или решение
  /// другое. У «списать» и «разместить» исполнение — само «Провести» в портале.
  final String? shippedBy;
  final DateTime? shippedAt;

  /// Своя проблема из очереди терминала: сервер о ней ещё не знает (ADHOC-35).
  final bool pending;

  /// Проблема ждёт решения офиса.
  bool get isOpen => decision.isEmpty;

  /// Момент решения — для показа и разделителей по дням; у открытой — момент фиксации.
  DateTime get resolvedAtTime =>
      resolvedAt == null ? createdAt : DateTime.parse(resolvedAt!);

  /// Возврат ещё ждёт отгрузки на складе.
  bool get awaitingShipment =>
      decision == ProblemDecision.supplierReturn && shippedAt == null;
}

/// Фильтр ленты: период по дням решения (по часам терминала). Пустые поля ленту не сужают.
class ResolvedProblemsQuery {
  const ResolvedProblemsQuery({this.from, this.to});

  final DateTime? from;
  final DateTime? to;
}

/// Открытые проблемы для вкладки «Текущие» (ADHOC-35).
class CurrentProblems {
  const CurrentProblems({
    this.pending = const [],
    this.open = const [],
    this.failure,
  });

  /// Свои неотправленные из очереди терминала — видны и без связи.
  final List<ProblemRecord> pending;

  /// Открытые проблемы склада с сервера; при [failure] — пусто.
  final List<ProblemRecord> open;

  /// Почему список склада не получен; `null` — получен.
  final Failure? failure;
}

/// Источник проблем склада для ТСД. Реализация — `ProblemRecordsRepositoryImpl` в `data`.
abstract interface class ProblemRecordsRepository {
  /// Страница ленты решённых, свежие решения сверху. [after] — последняя показанная запись
  /// (курсор). Только со связью.
  Future<Either<Failure, List<ProblemRecord>>> resolved({
    required ResolvedProblemsQuery query,
    ProblemRecord? after,
    int limit,
  });

  /// Открытые проблемы: свои неотправленные из очереди и открытые склада с сервера, свежие
  /// первыми. Своя проблема, которую сервер уже знает, показывается один раз — серверной.
  Future<CurrentProblems> current();
}
