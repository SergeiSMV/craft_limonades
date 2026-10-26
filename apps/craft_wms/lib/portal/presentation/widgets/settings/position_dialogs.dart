import 'package:flutter/material.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_dialog.dart';
import '../common/portal_text_field.dart';
import 'access_common.dart';
import 'rights_tree.dart';

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
    return PortalDialog(
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
              PortalTextField(
                controller: _name,
                hint: t.portal.positions.nameHint,
                autofocus: !editing,
              ),
              AppBoxes.kHeight16,
              AccessFieldLabel(t.portal.positions.rightsLabel),
              // Дерево длинное — прокручивается внутри диалога, название и кнопки на месте.
              Flexible(
                child: SingleChildScrollView(
                  child: RightsTree(selected: _rights, onChanged: onRights),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        accessCancel(context, label: t.portal.positions.cancel),
        NeumorphicTextButton(
          label: editing ? t.portal.positions.save : t.portal.positions.create,
          accent: true,
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
    builder: (ctx) => PortalDialog(
      title: t.portal.positions.deleteTitle,
      content: Text(
        t.portal.positions.deleteBody(name: name),
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      actions: [
        accessCancel(ctx, label: t.portal.positions.cancel, result: false),
        NeumorphicTextButton(
          label: t.portal.positions.delete,
          accent: true,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}
