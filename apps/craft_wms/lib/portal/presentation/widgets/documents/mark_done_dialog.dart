import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../ui/portal_button.dart';
import '../ui/portal_modal.dart';

/// Подтверждение «Провести» (P3-02, плоский стиль - ADHOC-56).
///
/// Спрашиваем, потому что вернуть документ в работу нельзя. Возвращает `true`, только если
/// оператор нажал «Провести»; «Отмена», крестик и закрытие окна - отказ.
Future<bool> showMarkDoneDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalModal(
      title: t.portal.documents.confirmTitle,
      content: Text(
        t.portal.documents.confirmBody,
        style: RegularTextStyles().regularInter13.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      actions: [
        portalCancel(ctx, label: t.portal.documents.confirmNo, result: false),
        PortalButton(
          label: t.portal.documents.confirmYes,
          kind: PortalButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
