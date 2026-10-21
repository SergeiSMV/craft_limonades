import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/resolved_problems.dart';

/// Лента решённых проблем с сервера (ADHOC-34): `GET /problems/resolved`. Только онлайн —
/// лента не кэшируется, как и «Завершённые» задания и перемещения.
@LazySingleton(as: ResolvedProblemsRepository)
class ResolvedProblemsRepositoryImpl implements ResolvedProblemsRepository {
  ResolvedProblemsRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Either<Failure, List<ResolvedProblem>>> page({
    required ResolvedProblemsQuery query,
    ResolvedProblem? after,
    int limit = 30,
  }) async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        ApiConst.problemsResolved,
        queryParameters: {
          if (query.from != null) 'from': _day(query.from!),
          if (query.to != null) 'to': _day(query.to!),
          if (after != null) 'before_resolved_at': after.resolvedAt,
          if (after != null) 'before_id': after.id,
          'limit': limit,
        },
      );
      return Right([
        for (final e in resp.data ?? const [])
          resolvedProblemFromJson(e as Map<String, dynamic>),
      ]);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// День фильтра в виде YYYY-MM-DD — сервер толкует его по времени склада.
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Решённая проблема из ответа сервера. Пустые строки необязательных полей — `null`:
/// сервер опускает их или отдаёт пустыми.
ResolvedProblem resolvedProblemFromJson(Map<String, dynamic> j) {
  String? opt(String key) {
    final v = j[key] as String?;
    return v == null || v.isEmpty ? null : v;
  }

  final task = j['return_task_number'] as int?;
  return ResolvedProblem(
    id: j['id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    createdBy: j['created_by'] as String? ?? '',
    cellAddress: j['cell_address'] as String? ?? '',
    loadUnitId: opt('load_unit_id'),
    reason: j['reason'] as String? ?? '',
    comment: j['comment'] as String? ?? '',
    mark: opt('mark'),
    fromWarehouse: j['from_warehouse'] as String? ?? '',
    toWarehouse: j['to_warehouse'] as String? ?? '',
    items: [
      for (final e in j['items'] as List? ?? const [])
        _item(e as Map<String, dynamic>),
    ],
    decision: j['decision'] as String? ?? '',
    docNumber: opt('doc_number'),
    docDate: opt('doc_date'),
    supplierName: opt('supplier_name'),
    returnTaskNumber: task == null || task == 0 ? null : task,
    resolvedBy: j['resolved_by'] as String? ?? '',
    resolvedAt: j['resolved_at'] as String,
    shippedBy: opt('shipped_by'),
    shippedAt: switch (opt('shipped_at')) {
      final v? => DateTime.parse(v),
      null => null,
    },
  );
}

ResolvedProblemItem _item(Map<String, dynamic> e) {
  final code = e['good_code'] as String? ?? '';
  return ResolvedProblemItem(
    goodName: e['good_name'] as String? ?? '',
    goodCode: code.isEmpty ? null : code,
    productionDate: e['production_date'] as String? ?? '',
    qty: e['qty'] as String? ?? '0',
    cellAddress: e['cell_address'] as String? ?? '',
  );
}
