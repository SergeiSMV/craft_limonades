import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Решённые проблемы склада на ТСД (ADHOC-34): вкладка «Завершённые» в «Проблемах склада».
///
/// Кладовщик видит, что офис решил по проблемам склада — всем, не только своим: списано по
/// документу 1С, размещено обратно в «Основной», уехало поставщику. Только онлайн, как ленты
/// «Завершённые» заданий и перемещений; открытые проблемы — забота офиса и сюда не попадают.

/// Решение офиса — как значение приходит с сервера.
abstract final class ProblemDecision {
  /// Списано по документу 1С.
  static const writeOff = 'write_off';

  /// Метка снята — товар снова в «Основном» на том же месте.
  static const place = 'place';

  /// Возврат поставщику: товар на складе возврата и в задании на отгрузку.
  static const supplierReturn = 'supplier_return';
}

/// Товар проблемы: что решение фактически взяло — товар, партия, количество, ячейка.
class ResolvedProblemItem {
  const ResolvedProblemItem({
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

/// Решённая проблема: что и где помечено, кем и когда, и что решил офис.
class ResolvedProblem {
  const ResolvedProblem({
    required this.id,
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
    required this.decision,
    this.docNumber,
    this.docDate,
    this.supplierName,
    this.returnTaskNumber,
    required this.resolvedBy,
    required this.resolvedAt,
    this.shippedBy,
    this.shippedAt,
  });

  final String id;
  final DateTime createdAt;

  /// Кто зафиксировал.
  final String createdBy;

  /// Где помечено.
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
  final List<ResolvedProblemItem> items;

  /// Решение — [ProblemDecision].
  final String decision;

  /// Документ списания 1С: номер и дата YYYY-MM-DD.
  final String? docNumber;
  final String? docDate;

  /// Возврат: кому и номер задания на отгрузку.
  final String? supplierName;
  final int? returnTaskNumber;

  /// Кто решил в портале.
  final String resolvedBy;

  /// Момент решения строкой, как его отдал сервер: это и курсор подгрузки, и сервер ждёт его
  /// до наносекунд — перевод в DateTime и обратно их терял бы.
  final String resolvedAt;

  /// Кто и когда отгрузил возврат поставщику на ТСД; `null` — ещё не отгружен или решение
  /// другое. У «списать» и «разместить» исполнение — само «Провести» в портале.
  final String? shippedBy;
  final DateTime? shippedAt;

  /// Момент решения — для показа и разделителей по дням.
  DateTime get resolvedAtTime => DateTime.parse(resolvedAt);

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

/// Источник ленты решённых проблем. Реализация — `ResolvedProblemsRepositoryImpl` в `data`.
abstract interface class ResolvedProblemsRepository {
  /// Страница ленты, свежие решения сверху. [after] — последняя показанная запись (курсор).
  Future<Either<Failure, List<ResolvedProblem>>> page({
    required ResolvedProblemsQuery query,
    ResolvedProblem? after,
    int limit,
  });
}
