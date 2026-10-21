import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';

/// Внутренний склад глазами портала (ADHOC-29): что показать и что с ним можно сделать.
class PortalWarehouse {
  const PortalWarehouse({
    required this.id,
    required this.code,
    required this.name,
    required this.isDefault,
    required this.isActive,
    required this.inUse,
  });

  factory PortalWarehouse.fromJson(Map<String, dynamic> j) => PortalWarehouse(
    id: j['id'] as String,
    code: j['code'] as String? ?? '',
    name: j['name'] as String? ?? '',
    isDefault: j['is_default'] as bool? ?? false,
    isActive: j['is_active'] as bool? ?? true,
    inUse: j['in_use'] as bool? ?? false,
  );

  final String id;
  final String code;
  final String name;

  /// Склад по умолчанию («Основной»): его нельзя ни скрыть, ни удалить.
  final bool isDefault;

  /// В выборе на ТСД; скрытым не помечают, но его остаток остаётся и подписывается.
  final bool isActive;

  /// Есть остаток или история — удалить нельзя, только скрыть.
  final bool inUse;

  /// Можно ли удалить: не по умолчанию и без остатка и истории.
  bool get canDelete => !isDefault && !inUse;
}

/// Справочник внутренних складов в портале (ADHOC-29): список и ведение — только admin.
///
/// Ошибки по существу (повтор кода, склад с остатком, склад по умолчанию) сервер объясняет
/// текстом в поле `error` — он приезжает в `ServerFailure.message` и показывается оператору.
@lazySingleton
class InternalWarehousesRepository {
  InternalWarehousesRepository(this._dio);

  final Dio _dio;

  /// Все склады, и скрытые; по умолчанию первым.
  Future<Either<Failure, List<PortalWarehouse>>> list() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.internalWarehouses);
    return [
      for (final e in resp.data ?? const [])
        PortalWarehouse.fromJson(e as Map<String, dynamic>),
    ];
  });

  /// Завести склад.
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

  /// Переименовать и (или) скрыть или вернуть в выбор.
  Future<Either<Failure, PortalWarehouse>> update(
    String id, {
    String? name,
    bool? isActive,
  }) => _call(() async {
    final resp = await _dio.patch<Map<String, dynamic>>(
      ApiConst.internalWarehouseById(id),
      data: {'name': ?name, 'is_active': ?isActive},
    );
    return PortalWarehouse.fromJson(resp.data!);
  });

  /// Удалить склад без остатка и истории.
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
