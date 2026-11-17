import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Внутренний склад глазами портала (ADHOC-29): что показать и что с ним можно сделать.
class PortalWarehouse {
  const PortalWarehouse({
    required this.id,
    required this.code,
    required this.name,
    required this.isDefault,
    required this.isActive,
    required this.inUse,
    this.allowPicking = false,
    this.systemRole = '',
  });

  factory PortalWarehouse.fromJson(Map<String, dynamic> j) => PortalWarehouse(
    id: j['id'] as String,
    code: j['code'] as String? ?? '',
    name: j['name'] as String? ?? '',
    isDefault: j['is_default'] as bool? ?? false,
    isActive: j['is_active'] as bool? ?? true,
    inUse: j['in_use'] as bool? ?? false,
    allowPicking: j['allow_picking'] as bool? ?? false,
    systemRole: j['system_role'] as String? ?? '',
  );

  final String id;
  final String code;
  final String name;

  /// Склад по умолчанию («Основной»): его нельзя ни скрыть, ни удалить.
  final bool isDefault;

  /// В выборе на ТСД; скрытым не помечают, но его остаток остаётся и подписывается.
  final bool isActive;

  /// Есть остаток или история - удалить нельзя, только скрыть.
  final bool inUse;

  /// Галочка «разрешить сборку» (P8-02): из товара склада можно собирать заказы.
  final bool allowPicking;

  /// Роль системного склада (P6-07-3, «Возврат поставщику»); пусто - обычный склад.
  final String systemRole;

  /// Системный: на него переводит программа (решение офиса), а не кладовщик - его нельзя ни
  /// скрыть, ни удалить.
  bool get isSystem => systemRole.isNotEmpty;

  /// Можно ли скрыть или вернуть в выбор: не по умолчанию и не системный.
  bool get canToggle => !isDefault && !isSystem;

  /// Можно ли удалить: не по умолчанию, не системный, без остатка и истории.
  bool get canDelete => canToggle && !inUse;

  /// Можно ли менять галочку «разрешить сборку»: системному складу сборка запрещена всегда.
  bool get canTogglePicking => !isSystem;
}

/// Справочник внутренних складов в портале (ADHOC-29): список и ведение - только admin.
///
/// Ошибки по существу (повтор кода, склад с остатком, склад по умолчанию) сервер объясняет
/// текстом в поле `error` - он приезжает в `ServerFailure.message` и показывается оператору.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `InternalWarehousesRepositoryImpl` в `data`.
abstract interface class InternalWarehousesRepository {
  /// Все склады, и скрытые; по умолчанию первым.
  Future<Either<Failure, List<PortalWarehouse>>> list();

  /// Завести склад.
  Future<Either<Failure, PortalWarehouse>> create({
    required String code,
    required String name,
  });

  /// Переименовать, скрыть или вернуть в выбор, разрешить или запретить сборку.
  Future<Either<Failure, PortalWarehouse>> update(
    String id, {
    String? name,
    bool? isActive,
    bool? allowPicking,
  });

  /// Удалить склад без остатка и истории.
  Future<Either<Failure, void>> delete(String id);
}
