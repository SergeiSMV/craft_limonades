import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/receipt_models.dart';

/// Итог приёмки: оприходована, ждёт связи или отклонена - и что делать дальше.
///
/// Три исхода разведены намеренно: «сохранена» без связи - это не провал, работа уже в очереди
/// и уйдёт сама; а отказ сервера требует действия человека, и сказать об этом надо прямо здесь.
class ReceiptFinishedView extends StatelessWidget {
  const ReceiptFinishedView({
    super.key,
    required this.outcome,
    required this.positions,
    this.rejectReason,
  });

  final ReceiptOutcome outcome;
  final int positions;
  final String? rejectReason;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, text) = switch (outcome) {
      ReceiptOutcome.posted => (
        Icons.check_circle,
        AppColors.kBadgeSuccessText,
        t.receipt.postedTitle,
        t.receipt.postedText(count: positions),
      ),
      ReceiptOutcome.queued => (
        Icons.cloud_upload_outlined,
        AppColors.kBadgeWarningText,
        t.receipt.queuedTitle,
        t.receipt.queuedText,
      ),
      ReceiptOutcome.rejected => (
        Icons.error_outline,
        AppColors.kDanger,
        t.receipt.rejectedTitle,
        t.receipt.rejectedText(reason: rejectReason ?? ''),
      ),
    };
    return Center(
      child: Padding(
        padding: AppInsets.all32,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: AppSizes.kIcon64),
            AppBoxes.kHeight16,
            Text(
              title,
              textAlign: TextAlign.center,
              style: SemiboldTextStyles().semiboldInter24,
            ),
            AppBoxes.kHeight8,
            Text(
              text,
              textAlign: TextAlign.center,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            AppBoxes.kHeight24,
            FilledButton(
              onPressed: () => context.router.maybePop(),
              child: Text(t.receipt.toHome),
            ),
          ],
        ),
      ),
    );
  }
}
