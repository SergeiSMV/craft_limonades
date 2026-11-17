import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import 'portal_button.dart';

/// Диалог портала в плоском стиле (ADHOC-56, модальное окно Shopify Polaris).
///
/// Что: белое окно - шапка с заголовком и крестиком, содержимое, подвал с действиями справа;
///      шапку и подвал отделяют линии.
/// Как: ширина - не больше [AppSizes.kPortalDialogWidth], на телефоне - во всю ширину с полями;
///      длинное содержимое прокручивается, шапка и подвал остаются на месте. Крестик закрывает
///      окно без результата, как «Отмена».
class PortalModal extends StatelessWidget {
  const PortalModal({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.maxWidth = AppSizes.kPortalDialogWidth,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  /// Предел ширины окна; шире - для таблиц со многими колонками.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.kCardBg,
      surfaceTintColor: Colors.transparent,
      insetPadding: AppInsets.all16,
      shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppInsets.modalHeader,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: SemiboldTextStyles().semiboldInter16.copyWith(
                        color: AppColors.kTextMain,
                      ),
                    ),
                  ),
                  PortalIconButton(
                    icon: Icons.close,
                    tooltip: t.portal.common.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 1, color: AppColors.kDivider),
            Flexible(
              child: SingleChildScrollView(
                padding: AppInsets.modalBody,
                child: content,
              ),
            ),
            const Divider(height: 1, thickness: 1, color: AppColors.kDivider),
            Padding(
              padding: AppInsets.modalFooter,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSizes.kChipSpacing,
                runSpacing: AppSizes.kChipSpacing,
                children: actions,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Отмена» диалога - текстовая кнопка, закрывает с [result].
Widget portalCancel(
  BuildContext context, {
  required String label,
  Object? result,
}) => PortalButton(
  label: label,
  kind: PortalButtonKind.plain,
  onPressed: () => Navigator.of(context).pop(result),
);

/// Подпись поля диалога - над полем или группой вариантов.
class PortalFieldLabel extends StatelessWidget {
  const PortalFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: AppInsets.bottom4,
    child: Text(
      text,
      style: SemiboldTextStyles().semiboldInter13.copyWith(
        color: AppColors.kTextMain,
      ),
    ),
  );
}

/// Отступ между полями диалога.
const portalFieldGap = AppBoxes.kHeight16;
