import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../ui/portal_button.dart';
import '../ui/portal_input.dart';
import '../ui/portal_modal.dart';

/// Диалог адреса напольной ячейки (ADHOC-61): новая ячейка ([current] нет) или новый адрес.
/// Возвращает введённый адрес; `null` — оператор передумал. Адрес проверяет и приводит к виду
/// справочника сервер: «d-h-п» станет «D-Н-П».
Future<String?> showFloorCellAddressDialog(
  BuildContext context, {
  String? current,
}) {
  final s = t.portal.cells.floor;
  final address = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final text = address.text.trim();
        if (text.isNotEmpty) Navigator.of(ctx).pop(text);
      }

      return PortalModal(
        title: current == null ? s.createTitle : s.renameTitle,
        content: _DialogBody(
          children: [
            PortalInput(
              controller: address,
              hint: s.addressHint,
              autofocus: true,
              onSubmitted: (_) => submit(),
            ),
            AppBoxes.kHeight8,
            Text(
              s.addressHelp,
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ],
        ),
        actions: [
          portalCancel(ctx, label: s.cancel),
          PortalButton(
            label: current == null ? s.create : s.save,
            kind: PortalButtonKind.primary,
            onPressed: submit,
          ),
        ],
      );
    },
  );
}

/// Подтверждение удаления напольной ячейки: удаляется только пустая, история остаётся.
Future<bool> showDeleteFloorCellDialog(
  BuildContext context, {
  required String address,
}) async {
  final s = t.portal.cells.floor;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalModal(
      title: s.deleteTitle(address: address),
      content: _DialogBody(
        children: [
          Text(
            s.deleteBody,
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ],
      ),
      actions: [
        portalCancel(ctx, label: s.cancel, result: false),
        PortalButton(
          label: s.delete,
          kind: PortalButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Содержимое диалога — не шире половины колонки, как у диалогов складов.
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
