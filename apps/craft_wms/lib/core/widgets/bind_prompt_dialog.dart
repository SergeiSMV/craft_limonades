import 'package:flutter/material.dart';

import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';

/// Спросить, привязывать ли отсканированный ШК к товару.
///
/// Общий для «Остатков» (ADHOC-06) и «Ввода остатков» (ADHOC-13): вторая фича попросила тот же
/// диалог с другим текстом, поэтому подписи стали параметрами, а не сидят внутри. Одинаковый
/// вопрос должен выглядеть одинаково, а звучать — по поводу.
/// Возвращает `true`, только если кладовщик нажал «Привязать»; закрытие диалога — отказ.
///
/// Зачем спрашивать, а не открывать выбор товара сразу, как это делает «Ввод остатков»: там скан
/// и есть текущая работа кладовщика, а «Остатки» — экран просмотра. Посторонний скан (чужая
/// этикетка, код на коробке рядом) не должен сам разворачивать поверх списка номенклатуру.
Future<bool> showBindPromptDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required String cancelLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.kNeumorphicBg,
      insetPadding: AppInsets.dialogInset,
      title: Text(
        title,
        style: SemiboldTextStyles().semiboldInter16.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
      // Ширина во всю доступную — иначе диалог сжимается по контенту и подписи кнопок
      // переносятся на 360dp экрана ТСД (та же причина, что в диалоге привязки P-FS-17).
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              body,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            AppBoxes.kHeight12,
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(cancelLabel),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return confirmed ?? false;
}
