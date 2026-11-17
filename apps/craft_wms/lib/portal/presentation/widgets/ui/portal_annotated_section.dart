import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Раздел с подписью (ADHOC-56, шаблон настроек Shopify Polaris).
///
/// Что: слева - заголовок, пояснение и действие раздела («Добавить»), справа - карточка.
/// Как: раскладка зависит от ширины, которая досталась разделу, а не от экрана: от
///      [AppSizes.kAnnotatedWidth] - две колонки 2 : 5, уже - подпись над карточкой. Поэтому
///      раздел ведёт себя одинаково в широком окне, в узком и на телефоне.
class PortalAnnotatedSection extends StatelessWidget {
  const PortalAnnotatedSection({
    super.key,
    required this.title,
    required this.description,
    required this.child,
    this.action,
  });

  final String title;
  final String description;

  /// Действие раздела под пояснением; `null` - без действия.
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final annotation = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
            AppBoxes.kHeight4,
            Text(
              description,
              style: RegularTextStyles().regularInter13.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            if (action != null) ...[AppBoxes.kHeight12, action!],
          ],
        );
        if (constraints.maxWidth < AppSizes.kAnnotatedWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [annotation, AppBoxes.kHeight12, child],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: annotation),
            AppBoxes.kWidth24,
            Expanded(flex: 5, child: child),
          ],
        );
      },
    );
  }
}
