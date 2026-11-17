import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../domain/movement_history.dart';
import '../domain/movement_models.dart';

/// История перемещений с сервера (ADHOC-28): `GET /movements…`. Только онлайн - лента
/// не кэшируется, как и «Завершённые» задания.
@LazySingleton(as: MovementHistoryRepository)
class MovementHistoryRepositoryImpl implements MovementHistoryRepository {
  MovementHistoryRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Either<Failure, List<MoveRecord>>> page({
    required MoveHistoryQuery query,
    MoveRecord? after,
    int limit = 30,
  }) => _get(
    ApiConst.movements,
    (data) => (data as List)
        .map((e) => recordFromJson(e as Map<String, dynamic>))
        .toList(),
    query: {
      if (query.from != null) 'from': _day(query.from!),
      if (query.to != null) 'to': _day(query.to!),
      if (query.executorId != null) 'executor': query.executorId,
      if (after != null) 'before_posted_at': after.postedAt,
      if (after != null) 'before_id': after.id,
      'limit': limit,
    },
  );

  @override
  Future<Either<Failure, List<MoveUser>>> executors() => _get(
    ApiConst.movementsExecutors,
    (data) => (data as List)
        .map((e) => userFromJson(e as Map<String, dynamic>))
        .toList(),
  );

  @override
  Future<Either<Failure, MoveRecordDetail>> record(String id) =>
      _get(ApiConst.movementById(id), (data) {
        final map = data as Map<String, dynamic>;
        return MoveRecordDetail(
          record: recordFromJson(map),
          lines: (map['lines'] as List? ?? [])
              .map((e) => lineFromJson(e as Map<String, dynamic>))
              .toList(),
        );
      });

  /// День фильтра в виде YYYY-MM-DD - сервер толкует его по времени склада.
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<Either<Failure, T>> _get<T>(
    String path,
    T Function(Object? data) parse, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final resp = await _dio.get<Object?>(path, queryParameters: query);
      return Right(parse(resp.data));
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}

/// Исполнитель из ответа сервера.
MoveUser userFromJson(Map<String, dynamic> j) => MoveUser(
  id: j['id'] as String? ?? '',
  fullName: j['full_name'] as String? ?? '',
);

/// Запись ленты из ответа сервера.
MoveRecord recordFromJson(Map<String, dynamic> j) => MoveRecord(
  id: j['id'] as String,
  kind: j['kind'] as String? ?? '',
  postedAt: j['posted_at'] as String,
  executor: userFromJson(j['executor'] as Map<String, dynamic>? ?? const {}),
  loadUnits: (j['load_units'] as num?)?.toInt() ?? 0,
  goods: (j['goods'] as num?)?.toInt() ?? 0,
  number: (j['number'] as num?)?.toInt() ?? 0,
);

/// Строка записи - в строку сеанса перемещения: история показывается теми же словами.
///
/// Количество сервер отдаёт десятичным текстом (без потери точности), сеанс держит его
/// числом - поэтому разбор свой, а не `MoveLine.fromJson` черновика.
MoveLine lineFromJson(Map<String, dynamic> j) {
  final good = j['good'] as Map<String, dynamic>?;
  final qty = j['qty'];
  return MoveLine(
    loadUnitId: j['load_unit_id'] as String?,
    good: good == null
        ? null
        : MoveGood(
            id: good['id'] as String,
            name: good['name'] as String? ?? '',
            code: good['code'] as String?,
            uom: good['uom'] as String? ?? '',
          ),
    productionDate: j['production_date'] as String?,
    qty: qty == null ? null : double.tryParse(qty.toString()),
    from: MovePlace.fromJson(j['from'] as Map<String, dynamic>),
    to: MovePlace.fromJson(j['to'] as Map<String, dynamic>),
  );
}
