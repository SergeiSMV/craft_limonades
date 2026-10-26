import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/stocktakes_repository.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_dialog.dart';
import '../common/portal_filter_chip.dart';
import 'scope_picker.dart';
import 'stocktake_labels.dart';

/// Заведённый пересчёт: номер и сколько ячеек дала область.
typedef StocktakeCreated = ({int number, int cells});

/// Новый пересчёт из портала (P10-05): вид области и её объекты — любые из шести видов.
/// Возвращает заведённый пересчёт; `null` — передумали.
Future<StocktakeCreated?> showStocktakeCreateDialog(BuildContext context) =>
    showDialog<StocktakeCreated>(
      context: context,
      builder: (_) => const _CreateDialog(),
    );

class _CreateDialog extends StatefulWidget {
  const _CreateDialog();

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _repo = getIt<StocktakesRepository>();

  String _scope = 'cells';

  /// Выбранные объекты области: id → подпись. Смена вида области их сбрасывает.
  final _selected = <String, String>{};
  bool _busy = false;
  String? _error;

  /// Сменить вид области.
  void selectScope(String kind) => setState(() {
    _scope = kind;
    _selected.clear();
    _error = null;
  });

  /// Отметить или снять объект области; внутренний склад и поставщик — тоже несколько.
  void toggle(ScopeObject o) => setState(() {
    if (_selected.remove(o.id) == null) _selected[o.id] = o.label;
    _error = null;
  });

  bool get _ready => _scope == 'all' || _selected.isNotEmpty;

  /// «Завести»: склад — склад справочника ячеек (пилот — один склад).
  Future<void> create() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    final wh = await _repo.warehouseId();
    if (!mounted) return;
    final warehouseId = wh.isRight ? wh.right : null;
    if (warehouseId == null) {
      setState(() {
        _busy = false;
        _error = wh.isLeft
            ? stocktakeErrorText(wh.left)
            : t.portal.stocktake.noWarehouse;
      });
      return;
    }
    final res = await _repo.create(
      warehouseId: warehouseId,
      scopeKind: _scope,
      objectIds: _selected.keys.toList(),
    );
    if (!mounted) return;
    if (res.isRight) {
      Navigator.of(context).pop(res.right);
      return;
    }
    setState(() {
      _busy = false;
      _error = stocktakeErrorText(res.left);
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    return PortalDialog(
      title: t.portal.stocktake.createTitle,
      content: SizedBox(
        width: AppSizes.kPortalDialogWidth,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.portal.stocktake.createScope, style: muted),
              AppBoxes.kHeight8,
              Wrap(
                spacing: AppSizes.kChipSpacing,
                runSpacing: AppSizes.kChipSpacing,
                children: [
                  for (final kind in kStocktakeScopes)
                    PortalFilterChip(
                      label: scopeLabel(kind),
                      selected: _scope == kind,
                      onTap: () => selectScope(kind),
                    ),
                ],
              ),
              AppBoxes.kHeight16,
              _picker(muted),
              if (_error case final e?) ...[
                AppBoxes.kHeight8,
                Text(e, style: muted.copyWith(color: AppColors.kDanger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.portal.stocktake.cancel),
        ),
        NeumorphicTextButton(
          label: t.portal.stocktake.createSubmit,
          accent: true,
          busy: _busy,
          onPressed: _ready ? create : () {},
        ),
      ],
    );
  }

  /// Выбор объектов вида области; у «всего склада» объектов нет — только пояснение.
  Widget _picker(TextStyle muted) {
    Future<Either<Failure, List<ScopeObject>>> Function(String) once(
      Future<Either<Failure, List<ScopeObject>>> Function() load,
    ) =>
        (_) => load();
    return switch (_scope) {
      'cells' => ScopePicker(
        key: const ValueKey('cells'),
        load: _repo.searchCells,
        serverSearch: true,
        hint: t.portal.stocktake.pickHintCells,
        selected: _selected,
        onToggle: toggle,
      ),
      'group' => ScopePicker(
        key: const ValueKey('group'),
        load: once(_repo.groups),
        hint: t.portal.stocktake.pickHintGroups,
        selected: _selected,
        onToggle: toggle,
      ),
      'supplier' => ScopePicker(
        key: const ValueKey('supplier'),
        load: once(_repo.suppliers),
        hint: t.portal.stocktake.pickHintSuppliers,
        selected: _selected,
        onToggle: toggle,
      ),
      'good' => ScopePicker(
        key: const ValueKey('good'),
        load: _repo.searchGoods,
        serverSearch: true,
        hint: t.portal.stocktake.pickHintGoods,
        selected: _selected,
        onToggle: toggle,
      ),
      'internal_warehouse' => ScopePicker(
        key: const ValueKey('internal_warehouse'),
        load: once(_repo.internalWarehouses),
        hint: t.portal.stocktake.scopeInternalWarehouse,
        selected: _selected,
        onToggle: toggle,
      ),
      _ => Text(t.portal.stocktake.scopeAllHint, style: muted),
    };
  }
}
