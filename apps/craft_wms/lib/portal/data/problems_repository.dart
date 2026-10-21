import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Решения офиса по проблеме (P6-07-3) — значения транспорта.
abstract final class ProblemDecision {
  /// Списать по документу 1С.
  static const writeOff = 'write_off';

  /// Разместить: снять метку, вернуть в «Основной».
  static const place = 'place';

  /// Возврат поставщику: склад возврата и задание.
  static const supplierReturn = 'supplier_return';
}

/// Товар проблемы: у открытой — что помечено сейчас, у решённой — что решение взяло.
class PortalProblemItem {
  const PortalProblemItem({
    required this.goodCode,
    required this.goodName,
    required this.productionDate,
    required this.qty,
    required this.cellAddress,
  });

  factory PortalProblemItem.fromJson(Map<String, dynamic> j) =>
      PortalProblemItem(
        goodCode: j['good_code'] as String? ?? '',
        goodName: j['good_name'] as String? ?? '',
        productionDate: j['production_date'] as String? ?? '',
        qty: double.tryParse(j['qty'] as String? ?? '') ?? 0,
        cellAddress: j['cell_address'] as String? ?? '',
      );

  final String goodCode;
  final String goodName;

  /// Дата выпуска партии, ISO `YYYY-MM-DD`.
  final String productionDate;
  final double qty;
  final String cellAddress;
}

/// Проблема склада в рабочем списке офиса (P6-07-3).
class PortalProblem {
  const PortalProblem({
    required this.id,
    required this.createdAt,
    required this.createdBy,
    required this.cellAddress,
    required this.loadUnitId,
    required this.reason,
    required this.comment,
    required this.mark,
    required this.fromWarehouse,
    required this.toWarehouse,
    required this.items,
    required this.decisions,
    required this.suggestedSupplierId,
    required this.resolved,
    required this.decision,
    required this.docNumber,
    required this.docDate,
    required this.supplierName,
    required this.returnTaskNumber,
    required this.resolvedBy,
    required this.resolvedAt,
  });

  factory PortalProblem.fromJson(Map<String, dynamic> j) => PortalProblem(
    id: j['id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    createdBy: j['created_by'] as String? ?? '',
    cellAddress: j['cell_address'] as String? ?? '',
    loadUnitId: j['load_unit_id'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
    comment: j['comment'] as String? ?? '',
    mark: j['mark'] as String? ?? '',
    fromWarehouse: j['from_warehouse'] as String? ?? '',
    toWarehouse: j['to_warehouse'] as String? ?? '',
    items: [
      for (final e in j['items'] as List<dynamic>? ?? const [])
        PortalProblemItem.fromJson(e as Map<String, dynamic>),
    ],
    decisions: [
      for (final e in j['decisions'] as List<dynamic>? ?? const []) e as String,
    ],
    suggestedSupplierId: j['suggested_supplier_id'] as String? ?? '',
    resolved: j['status'] == 'resolved',
    decision: j['decision'] as String? ?? '',
    docNumber: j['doc_number'] as String? ?? '',
    docDate: j['doc_date'] as String? ?? '',
    supplierName: j['supplier_name'] as String? ?? '',
    returnTaskNumber: (j['return_task_number'] as num?)?.toInt() ?? 0,
    resolvedBy: j['resolved_by'] as String? ?? '',
    resolvedAt: j['resolved_at'] == null
        ? null
        : DateTime.parse(j['resolved_at'] as String),
  );

  final String id;
  final DateTime createdAt;

  /// Кто зафиксировал на ТСД.
  final String createdBy;

  /// Ячейка пометки.
  final String cellAddress;

  /// Короб целиком; пусто — товар.
  final String loadUnitId;

  /// Причина — значение транспорта (`breakage`, `spoilage` …).
  final String reason;
  final String comment;

  /// Марка ЧЗ («не наша марка»).
  final String mark;

  /// Откуда помечено и какой меткой («Основной» → «Брак»).
  final String fromWarehouse;
  final String toWarehouse;
  final List<PortalProblemItem> items;

  /// Решения, допустимые при причине, в порядке показа — таблицу держит сервер.
  final List<String> decisions;

  /// Поставщик товара по справочнику — подсказка для возврата; пусто — разные или не указан.
  final String suggestedSupplierId;

  final bool resolved;
  final String decision;

  /// Документ списания 1С: номер и дата (ISO).
  final String docNumber;
  final String docDate;

  /// Кому возврат и номер задания возврата.
  final String supplierName;
  final int returnTaskNumber;
  final String resolvedBy;
  final DateTime? resolvedAt;

  /// Короткий код короба — как на ярлыке: последние восемь знаков идентификатора.
  String get loadUnitCode => loadUnitId.isEmpty
      ? ''
      : loadUnitId.replaceAll('-', '').substring(24).toUpperCase();
}

/// Поставщик — вариант выбора для возврата.
class PortalSupplier {
  const PortalSupplier({required this.id, required this.name});

  factory PortalSupplier.fromJson(Map<String, dynamic> j) =>
      PortalSupplier(id: j['id'] as String, name: j['name'] as String? ?? '');

  final String id;
  final String name;
}

/// Решение, собранное в диалоге: вид и поля своего вида.
typedef ProblemResolution = ({
  String decision,
  String docNumber,
  String docDate,
  String supplierId,
});

/// «Проблемы склада» в портале (P6-07-3): рабочий список и решение офиса — только admin.
///
/// Отказ по существу (решение недоступно, товар проблемы ушёл со склада-метки, уже решено)
/// сервер объясняет текстом в поле `error` — он приезжает в `ServerFailure.message`.
@lazySingleton
class ProblemsRepository {
  ProblemsRepository(this._dio);

  final Dio _dio;

  /// Все проблемы: открытые сверху, свежие первыми.
  Future<Either<Failure, List<PortalProblem>>> list() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.problems);
    return [
      for (final e in resp.data ?? const [])
        PortalProblem.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Справочник поставщиков — выбор, кому возвращать.
  Future<Either<Failure, List<PortalSupplier>>> suppliers() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.suppliers);
    return [
      for (final e in resp.data ?? const [])
        PortalSupplier.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// «Провести» решение по проблеме. Поля чужого вида не отправляются.
  Future<Either<Failure, void>> resolve(String id, ProblemResolution r) =>
      _call(
        () => _dio.post<void>(
          ApiConst.problemResolve(id),
          data: {
            'decision': r.decision,
            if (r.decision == ProblemDecision.writeOff) ...{
              'doc_number': r.docNumber,
              'doc_date': r.docDate,
            },
            if (r.decision == ProblemDecision.supplierReturn)
              'supplier_id': r.supplierId,
          },
        ),
      );

  Future<Either<Failure, T>> _call<T>(Future<T> Function() run) async {
    try {
      return Right(await run());
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      final data = e.response?.data;
      final message = data is Map ? data['error'] as String? : null;
      return Left(Failure.server(code, message));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
