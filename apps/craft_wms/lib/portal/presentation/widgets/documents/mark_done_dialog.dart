import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../common/neumorphic_text_button.dart';
import '../common/portal_dialog.dart';

/// Подтверждение «Отметить выполненным» (P3-02, вид — ADHOC-25).
///
/// Спрашиваем, потому что вернуть документ в работу нельзя. Возвращает `true`, только если
/// оператор нажал «Отметить»; закрытие диалога — отказ.
Future<bool> showMarkDoneDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => PortalDialog(
      title: t.portal.documents.confirmTitle,
      content: Text(
        t.portal.documents.confirmBody,
        style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMain),
      ),
      actions: [
        // «Отмена» — текстом и нейтральным цветом: отказ не должен весить столько же, сколько
        // действие, а цвет бренда остаётся только у действия — иначе «Отмена» и «Отметить»
        // различаются лишь рамкой кнопки.
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.kTextMuted),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.portal.documents.confirmNo),
        ),
        NeumorphicTextButton(
          label: t.portal.documents.confirmYes,
          accent: true,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
