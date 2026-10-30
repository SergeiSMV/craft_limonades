import 'package:flutter/material.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import 'rights_tree.dart';
import '../ui/portal_modal.dart';
import '../ui/portal_input.dart';
import '../ui/portal_button.dart';

/// Название и права должности; `null` — оператор передумал.
typedef PositionDraft = ({String name, List<String> rights});

/// Диалог должности (ADHOC-50): название и права деревом с галочками — приложение, раздел,
/// действия. [current] — правка
/// существующей, без него — новая.
Future<PositionDraft?> showPositionDialog(
  BuildContext context, {
  PositionDraft? current,
}) => showDialog<PositionDraft>(
  context: context,
  builder: (_) => _PositionDialog(current: current),
);

class _PositionDialog extends StatefulWidget {
  const _PositionDialog({this.current});

  final PositionDraft? current;

  @override
  State<_PositionDialog> createState() => _PositionDialogState();
}

class _PositionDialogState extends State<_PositionDialog> {
  late final _name = TextEditingController(text: widget.current?.name ?? '');
  late final Set<String> _rights = {...?widget.current?.rights};

  /// Новый набор отмеченных действий из дерева.
  void onRights(Set<String> rights) => setState(
    () => _rights
      ..clear()
      ..addAll(rights),
  );

  /// Сохранить: права — в порядке показа.
  void submit() => Navigator.of(context).pop((
    name: _name.text.trim(),
    rights: [
      for (final app in rightsTree())
        for (final code in app.codes)
          if (_rights.contains(code)) code,
    ],
  ));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.current != null;
    return PortalModal(
      title: editing
          ? t.portal.positions.editTitle
          : t.portal.positions.createTitle,
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
                hint: t.portal.positions.nameHint,
                autofocus: !editing,
              ),
              AppBoxes.kHeight16,
              PortalFieldLabel(t.portal.positions.rightsLabel),
              // Дерево длинное — прокручивается в окне, шапка и кнопки диалога на месте.
              RightsTree(selected: _rights, onChanged: onRights),
            ],
          ),
        ),
      ),
      actions: [
        portalCancel(context, label: t.portal.positions.cancel),
        PortalButton(
          label: editing ? t.portal.positions.save : t.portal.positions.create,
          kind: PortalButtonKind.primary,
          onPressed: submit,
        ),
      ],
    );
  }
}

/// Подтверждение удаления должности без пользователей.
Future<bool> showDeletePositionDialog(
  BuildContext context, {
  required String name,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalModal(
      title: t.portal.positions.deleteTitle,
      content: Text(
        t.portal.positions.deleteBody(name: name),
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      actions: [
        portalCancel(ctx, label: t.portal.positions.cancel, result: false),
        PortalButton(
          label: t.portal.positions.delete,
          kind: PortalButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}
