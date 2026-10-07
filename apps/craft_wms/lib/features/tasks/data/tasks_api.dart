import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import 'tasks_models.dart';

/// Сетевой источник заданий склада (P5-02-1): `GET /tasks…`, взятие и отказ.
/// Экраны сюда не ходят — между ними и сетью стоит `TasksRepository` с кэшем текущих.
@lazySingleton
class TasksApi {
  TasksApi(this._dio);

  final Dio _dio;

  /// Текущие задания: пул и свои взятые, с позициями.
  Future<Either<Failure, List<WarehouseTask>>> current() => _get(
    ApiConst.tasks,
    (data) => (data as List)
        .map((e) => WarehouseTask.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// Карточка задания с заходами.
  Future<Either<Failure, (WarehouseTask, List<TaskSession>)>> detail(
    String id,
  ) => _get(ApiConst.taskById(id), (data) {
    final map = data as Map<String, dynamic>;
    final sessions = (map['sessions'] as List? ?? [])
        .map((e) => TaskSession.fromJson(e as Map<String, dynamic>))
        .toList();
    return (WarehouseTask.fromJson(map), sessions);
  });

  /// Взять задание в работу.
  Future<Either<Failure, void>> take(String id) => _post(ApiConst.taskTake(id));

  /// Отказаться от задания: оно возвращается в пул.
  Future<Either<Failure, void>> release(String id) =>
      _post(ApiConst.taskRelease(id));

  /// Страница ленты «Завершённые». [after] — последняя показанная запись (курсор подгрузки).
  Future<Either<Failure, List<CompletedTask>>> completed({
    required CompletedFilter filter,
    CompletedTask? after,
    int limit = 30,
  }) => _get(
    ApiConst.tasksCompleted,
    (data) => (data as List)
        .map((e) => CompletedTask.fromJson(e as Map<String, dynamic>))
        .toList(),
    query: {
      if (filter.from != null) 'from': _day(filter.from!),
      if (filter.to != null) 'to': _day(filter.to!),
      if (filter.executor != null) 'executor': filter.executor!.id,
      if (filter.kind != null) 'kind': filter.kind,
      if (after != null) 'before_completed_at': after.completedAt,
      if (after != null) 'before_id': after.id,
      'limit': limit,
    },
  );

  /// Варианты фильтра ленты по исполнителю.
  Future<Either<Failure, List<TaskUser>>> executors() => _get(
    ApiConst.tasksExecutors,
    (data) => (data as List)
        .map((e) => TaskUser.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// День фильтра в виде YYYY-MM-DD — сервер толкует его по времени склада.
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

  Future<Either<Failure, void>> _post(String path) async {
    try {
      await _dio.post<void>(path);
      return const Right(null);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}
