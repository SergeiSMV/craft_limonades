import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/internal_warehouses_repository.dart';
import '../common/neumorphic_plate.dart';
import '../common/neumorphic_text_button.dart';
import 'warehouse_dialogs.dart';
import 'warehouse_row.dart';

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
    return NeumorphicPlate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.portal.warehouses.title,
                      style: SemiboldTextStyles().semiboldInter20.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                    AppBoxes.kHeight4,
                    Text(
                      t.portal.warehouses.description,
                      style: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AppBoxes.kWidth16,
              NeumorphicTextButton(
                label: t.portal.warehouses.add,
                icon: Icons.add,
                accent: true,
                busy: _busyId == '',
                onPressed: create,
              ),
            ],
          ),
          AppBoxes.kHeight16,
          if (_loading && items == null)
            const Center(child: CircularProgressIndicator())
          else
            for (final w in items ?? const <PortalWarehouse>[])
              WarehouseRow(
                warehouse: w,
                busy: _busyId == w.id,
                onRename: () => rename(w),
                onToggle: () => toggle(w),
                onDelete: () => delete(w),
              ),
          if (_error != null) ...[
            AppBoxes.kHeight16,
            Text(
              _error!,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kDanger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
