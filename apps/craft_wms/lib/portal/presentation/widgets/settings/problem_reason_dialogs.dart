import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../domain/problems/problems_repository.dart';
import 'access_common.dart';
import 'problem_reason_rows.dart';
import '../ui/portal_modal.dart';
import '../ui/portal_input.dart';
import '../ui/portal_button.dart';
import '../ui/portal_choice.dart';

/// Диалоги справочника причин и вариантов решения (ADHOC-55).

/// Название, флаг комментария и варианты причины; `null` - оператор передумал.
typedef ProblemReasonDraft = ({
  String name,
  bool commentRequired,
  List<String> resolutions,
});

/// Название и действие варианта; `null` - оператор передумал.
typedef ResolutionVariantDraft = ({String name, String action});

/// Диалог причины: название, «комментарий обязателен» и варианты решения галочками.
/// [current] - правка существующей, без него - новая.
///
/// Варианты «пересорт» предлагаются только причине «Пересорт», а ей - только они: сервер
/// другое сочетание не примет. Выключенный вариант виден, только пока он отмечен у причины.
Future<ProblemReasonDraft?> showProblemReasonDialog(
  BuildContext context, {
  ProblemReason? current,
  required List<ResolutionVariant> variants,
}) => showDialog<ProblemReasonDraft>(
  context: context,
  builder: (_) => _ReasonDialog(current: current, variants: variants),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({this.current, required this.variants});

  final ProblemReason? current;
  final List<ResolutionVariant> variants;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  late final _name = TextEditingController(text: widget.current?.name ?? '');
  late bool _comment = widget.current?.commentRequired ?? false;
  late final Set<String> _selected = {...?widget.current?.resolutions};
  String? _error;

  /// Варианты на выбор: по правилу «пересорт только у пересорта»; выключенные - если отмечены.
  List<ResolutionVariant> get _choices {
    final regrade = widget.current?.code == ProblemReasonCodes.regrade;
    return [
      for (final v in widget.variants)
        if ((v.action == ProblemDecision.regrade) == regrade &&
            (v.isActive || _selected.contains(v.id)))
          v,
    ];
  }

  /// Отметить вариант или снять отметку.
  void toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
    _error = null;
  });

  /// Сохранить: название и хотя бы один вариант; варианты - в порядке справочника.
  void submit() {
    final name = _name.text.trim();
    final resolutions = [
      for (final v in _choices)
        if (_selected.contains(v.id)) v.id,
    ];
    final error = name.isEmpty
        ? t.portal.problemReasons.needName
        : resolutions.isEmpty
        ? t.portal.problemReasons.needResolution
        : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(
      context,
    ).pop((name: name, commentRequired: _comment, resolutions: resolutions));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.portal.problemReasons;
    final editing = widget.current != null;
    final choices = _choices;
    return PortalModal(
      title: editing ? tr.editTitle : tr.createTitle,
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppSizes.kContentMaxWidth / 2,
        ),
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PortalInput(
                controller: _name,
                hint: tr.nameHint,
                autofocus: !editing,
              ),
              AppBoxes.kHeight8,
              _check(
                label: tr.commentRequired,
                value: _comment,
                onTap: () => setState(() => _comment = !_comment),
              ),
              AppBoxes.kHeight16,
              PortalFieldLabel(tr.resolutionsLabel),
              if (choices.isEmpty)
                Text(
                  tr.noResolutions,
                  style: RegularTextStyles().regularInter14.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              for (final v in choices)
                _check(
                  label: v.isActive
                      ? v.name
                      : '${v.name} · ${tr.markVariantInactive}',
                  value: _selected.contains(v.id),
                  onTap: () => toggle(v.id),
                ),
              if (_error != null) ...[AppBoxes.kHeight12, AccessError(_error!)],
            ],
          ),
        ),
      ),
      actions: [
        portalCancel(context, label: tr.cancel),
        PortalButton(
          label: editing ? tr.save : tr.create,
          kind: PortalButtonKind.primary,
          onPressed: submit,
        ),
      ],
    );
  }

  /// Строка с галочкой - как действие в дереве прав.
  Widget _check({
    required String label,
    required bool value,
    required VoidCallback onTap,
  }) => Row(
    children: [
      Checkbox(
        value: value,
        activeColor: AppColors.kButtonPrimary,
        onChanged: (_) => onTap(),
      ),
      Expanded(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: AppInsets.v8,
            child: Text(
              label,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Диалог варианта решения: название и - только у нового - действие.
Future<ResolutionVariantDraft?> showResolutionVariantDialog(
  BuildContext context, {
  ResolutionVariant? current,
}) => showDialog<ResolutionVariantDraft>(
  context: context,
  builder: (_) => _VariantDialog(current: current),
);

class _VariantDialog extends StatefulWidget {
  const _VariantDialog({this.current});

  final ResolutionVariant? current;

  @override
  State<_VariantDialog> createState() => _VariantDialogState();
}

class _VariantDialogState extends State<_VariantDialog> {
  late final _name = TextEditingController(text: widget.current?.name ?? '');
  late String? _action = widget.current?.action;
  String? _error;

  /// Выбрать действие нового варианта.
  void choose(String action) => setState(() {
    _action = action;
    _error = null;
  });

  /// Сохранить: название и действие.
  void submit() {
    final name = _name.text.trim();
    final action = _action;
    final error = name.isEmpty
        ? t.portal.problemReasons.needName
        : action == null
        ? t.portal.problemReasons.needAction
        : null;
    if (error != null || action == null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop((name: name, action: action));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.portal.problemReasons;
    final editing = widget.current != null;
    return PortalModal(
      title: editing ? tr.variantEditTitle : tr.variantCreateTitle,
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppSizes.kContentMaxWidth / 2,
        ),
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PortalInput(
                controller: _name,
                hint: tr.variantNameHint,
                autofocus: true,
                onSubmitted: (_) => submit(),
              ),
              AppBoxes.kHeight16,
              PortalFieldLabel(tr.actionLabel),
              // Действие у существующего варианта не меняется - только показывается.
              if (editing)
                Text(
                  resolutionActionLabel(widget.current!.action),
                  style: RegularTextStyles().regularInter14.copyWith(
                    color: AppColors.kTextMain,
                  ),
                )
              else
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  children: [
                    for (final a in const [
                      ProblemDecision.writeOff,
                      ProblemDecision.place,
                      ProblemDecision.supplierReturn,
                      ProblemDecision.regrade,
                    ])
                      PortalChoice(
                        label: resolutionActionLabel(a),
                        selected: _action == a,
                        onTap: () => choose(a),
                      ),
                  ],
                ),
              if (_error != null) ...[AppBoxes.kHeight12, AccessError(_error!)],
            ],
          ),
        ),
      ),
      actions: [
        portalCancel(context, label: tr.cancel),
        PortalButton(
          label: editing ? tr.save : tr.create,
          kind: PortalButtonKind.primary,
          onPressed: submit,
        ),
      ],
    );
  }
}
