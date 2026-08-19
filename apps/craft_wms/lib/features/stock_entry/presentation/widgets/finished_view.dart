import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Итог ввода: сколько строк записано, куда смотреть, кнопка на главную.
class FinishedView extends StatelessWidget {
  const FinishedView({super.key, required this.written});

  final int written;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppInsets.all32,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle,
              color: AppColors.kBadgeSuccessText,
              size: AppSizes.kIcon64,
            ),
            AppBoxes.kHeight16,
            Text(
              t.stockEntry.finishedTitle,
              style: SemiboldTextStyles().semiboldInter24,
            ),
            AppBoxes.kHeight8,
            Text(
              t.stockEntry.finishedText(written: written),
              textAlign: TextAlign.center,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            AppBoxes.kHeight24,
            FilledButton(
              onPressed: () => context.router.maybePop(),
              child: Text(t.stockEntry.toHome),
            ),
          ],
        ),
      ),
    );
  }
}
