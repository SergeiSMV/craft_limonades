import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';
import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/internal_warehouses/internal_warehouses_repository.dart';

/// Справочник внутренних складов в портале (ADHOC-29): список и ведение - только admin.
///
/// Ошибки по существу (повтор кода, склад с остатком, склад по умолчанию) сервер объясняет
/// текстом в поле `error` - он приезжает в `ServerFailure.message` и показывается оператору.
@LazySingleton(as: InternalWarehousesRepository)
class InternalWarehousesRepositoryImpl implements InternalWarehousesRepository {
  InternalWarehousesRepositoryImpl(this._dio);

  final Dio _dio;

  /// Все склады, и скрытые; по умолчанию первым.
  @override
  Future<Either<Failure, List<PortalWarehouse>>> list() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.internalWarehouses);
    return [
      for (final e in resp.data ?? const [])
        PortalWarehouse.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести склад.
  @override
  Future<Either<Failure, PortalWarehouse>> create({
    required String code,
    required String name,
  }) => _call(() async {
    final resp = await _dio.post<Map<String, dynamic>>(
      ApiConst.internalWarehouses,
      data: {'code': code, 'name': name},
    );
    return PortalWarehouse.fromJson(resp.data!);
  });

  /// Переименовать, скрыть или вернуть в выбор, разрешить или запретить сборку.
  @override
  Future<Either<Failure, PortalWarehouse>> update(
    String id, {
    String? name,
    bool? isActive,
    bool? allowPicking,
  }) => _call(() async {
    final resp = await _dio.patch<Map<String, dynamic>>(
      ApiConst.internalWarehouseById(id),
      data: {
        'name': ?name,
        'is_active': ?isActive,
        'allow_picking': ?allowPicking,
      },
    );
    return PortalWarehouse.fromJson(resp.data!);
  });

  /// Удалить склад без остатка и истории.
  @override
  Future<Either<Failure, void>> delete(String id) =>
      _call(() => _dio.delete<void>(ApiConst.internalWarehouseById(id)));

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
