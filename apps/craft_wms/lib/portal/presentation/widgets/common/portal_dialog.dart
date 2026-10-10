import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/theme/semibold_text.dart';

/// Диалог портала в неоморфном стиле (ADHOC-25).
///
/// Что: общая рамка диалогов вкладок — заголовок, содержимое, ряд действий справа.
/// Зачем: подтверждение «Выполнено» и история документа должны выглядеть одинаково; две
///        самостоятельные вёрстки разошлись бы на первой правке шрифта или отступа.
/// Как: поверхность — фон рабочей области портала, чтобы неоморфные кнопки действий
///      «выдавливались» из неё так же, как в списке. Действия передаёт вызывающий:
///      неоморфные кнопки и текстовая «Отмена».
class PortalDialog extends StatelessWidget {
  const PortalDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.kBg,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular16),
      title: Text(
        title,
        style: SemiboldTextStyles().semiboldInter20.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      content: content,
      actionsPadding: AppInsets.dialogActions,
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) AppBoxes.kWidth24,
              actions[i],
            ],
          ],
        ),
      ],
    );
  }
}
