import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/internal_warehouses_repository.dart';
import 'warehouse_dialogs.dart';
import 'warehouse_row.dart';
import '../ui/portal_annotated_section.dart';
import '../ui/portal_button.dart';
import 'access_common.dart';

/// Раздел «Внутренние склады» в настройках портала (ADHOC-29).
///
/// Что: склады, которыми кладовщик помечает товар на ТСД («Брак», «Изолятор» …), — завести,
/// переименовать, скрыть или вернуть в выбор, удалить. «Основной» (склад по умолчанию) только
/// переименовывается. Склад с остатком или историей не удаляется — его скрывают: остаток
/// остаётся и на ТСД подписан, но новым товаром склад больше не помечают.
class WarehousesSection extends StatefulWidget {
  const WarehousesSection({super.key});

  @override
  State<WarehousesSection> createState() => _WarehousesSectionState();
}

class _WarehousesSectionState extends State<WarehousesSection> {
  final _repo = getIt<InternalWarehousesRepository>();

  List<PortalWarehouse>? _items;
  bool _loading = true;

  /// Склад, с которым идёт действие; пустая строка — заводится новый.
  String? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Перечитать список с сервера.
  Future<void> load() async {
    setState(() => _loading = true);
    final res = await _repo.list();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = _text(f), (items) {
        _items = items;
        _error = null;
      });
    });
  }

  /// Завести склад: код и имя — в диалоге.
  Future<void> create() async {
    final draft = await showCreateWarehouseDialog(context);
    if (draft == null || !mounted) return;
    await _run('', () => _repo.create(code: draft.code, name: draft.name));
  }

  /// Переименовать склад.
  Future<void> rename(PortalWarehouse w) async {
    final name = await showRenameWarehouseDialog(context, current: w.name);
    if (name == null || name == w.name || !mounted) return;
    await _run(w.id, () => _repo.update(w.id, name: name));
  }

  /// Скрыть склад из выбора на ТСД или вернуть его.
  Future<void> toggle(PortalWarehouse w) =>
      _run(w.id, () => _repo.update(w.id, isActive: !w.isActive));

  /// Удалить склад без остатка и истории — после подтверждения.
  Future<void> delete(PortalWarehouse w) async {
    if (!await showDeleteWarehouseDialog(context, name: w.name) || !mounted) {
      return;
    }
    await _run(w.id, () => _repo.delete(w.id));
  }

  /// Выполнить действие и перечитать список; отказ сервера — текстом под списком.
  Future<void> _run(
    String id,
    Future<Either<Failure, Object?>> Function() action,
  ) async {
    setState(() {
      _busyId = id;
      _error = null;
    });
    final res = await action();
    if (!mounted) return;
    setState(() => _busyId = null);
    if (res.isLeft) {
      setState(() => _error = _text(res.left));
      return;
    }
    await load();
  }

  /// Текст ошибки: отказ по существу сервер объясняет сам.
  String _text(Failure f) => switch (f) {
    ServerFailure(:final message?) => message,
    ServerFailure(:final statusCode) => t.portal.warehouses.errorCode(
      code: statusCode,
    ),
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return PortalAnnotatedSection(
      title: t.portal.warehouses.title,
      description: t.portal.warehouses.description,
      action: PortalButton(
        label: t.portal.warehouses.add,
        icon: Icons.add,
        busy: _busyId == '',
        onPressed: create,
      ),
      child: SettingsListCard(
        loading: _loading && items == null,
        error: _error,
        rows: [
          for (final w in items ?? const <PortalWarehouse>[])
            WarehouseRow(
              warehouse: w,
              busy: _busyId == w.id,
              onRename: () => rename(w),
              onToggle: () => toggle(w),
              onDelete: () => delete(w),
            ),
        ],
      ),
    );
  }
}
