import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_dialog.dart';
import '../common/portal_text_field.dart';

/// Код и имя нового склада; `null` — оператор передумал.
typedef WarehouseDraft = ({String code, String name});

/// Диалог «Новый склад»: код (латиница, для отчётов) и имя (как видит кладовщик).
Future<WarehouseDraft?> showCreateWarehouseDialog(BuildContext context) {
  final code = TextEditingController();
  final name = TextEditingController();
  return showDialog<WarehouseDraft>(
    context: context,
    builder: (ctx) {
      void submit() => Navigator.of(
        ctx,
      ).pop((code: code.text.trim(), name: name.text.trim()));
      return PortalDialog(
        title: t.portal.warehouses.createTitle,
        content: _DialogBody(
          children: [
            PortalTextField(
              controller: name,
              hint: t.portal.warehouses.nameHint,
              autofocus: true,
            ),
            AppBoxes.kHeight16,
            PortalTextField(
              controller: code,
              hint: t.portal.warehouses.codeHint,
              onSubmitted: (_) => submit(),
            ),
            AppBoxes.kHeight8,
            Text(
              t.portal.warehouses.codeHelp,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ],
        ),
        actions: [
          _cancel(ctx),
          NeumorphicTextButton(
            label: t.portal.warehouses.create,
            accent: true,
            onPressed: submit,
          ),
        ],
      );
    },
  );
}

/// Диалог «Переименовать»; возвращает новое имя.
Future<String?> showRenameWarehouseDialog(
  BuildContext context, {
  required String current,
}) {
  final name = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() => Navigator.of(ctx).pop(name.text.trim());
      return PortalDialog(
        title: t.portal.warehouses.renameTitle,
        content: _DialogBody(
          children: [
            PortalTextField(
              controller: name,
              hint: t.portal.warehouses.nameHint,
              autofocus: true,
              onSubmitted: (_) => submit(),
            ),
          ],
        ),
        actions: [
          _cancel(ctx),
          NeumorphicTextButton(
            label: t.portal.warehouses.save,
            accent: true,
            onPressed: submit,
          ),
        ],
      );
    },
  );
}

/// Подтверждение удаления: склад без остатка и истории удаляется насовсем.
Future<bool> showDeleteWarehouseDialog(
  BuildContext context, {
  required String name,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalDialog(
      title: t.portal.warehouses.deleteTitle,
      content: _DialogBody(
        children: [
          Text(
            t.portal.warehouses.deleteBody(name: name),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ],
      ),
      actions: [
        _cancel(ctx, result: false),
        NeumorphicTextButton(
          label: t.portal.warehouses.delete,
          accent: true,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// «Отмена» — текстом и нейтральным цветом, как в подтверждении «Провести».
Widget _cancel(BuildContext ctx, {Object? result}) => TextButton(
  style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
  onPressed: () => Navigator.of(ctx).pop(result),
  child: Text(t.portal.warehouses.cancel),
);

/// Содержимое диалога — не шире половины колонки, как история документа.
class _DialogBody extends StatelessWidget {
  const _DialogBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppSizes.kContentMaxWidth / 2),
    child: SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
