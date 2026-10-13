import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/movement_state.dart';

/// Итог сеанса: проведён, ушёл в очередь, отклонён. Одна кнопка — вернуться в меню.
class MoveOutcomeView extends StatelessWidget {
  const MoveOutcomeView({
    super.key,
    required this.outcome,
    required this.reason,
    required this.onDone,
  });

  final MoveOutcome outcome;
  final String? reason;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (outcome) {
      MoveOutcome.posted => (
        t.movement.outcomePosted,
        AppColors.kBadgeSuccessText,
      ),
      MoveOutcome.queued => (
        t.movement.outcomeQueued,
        AppColors.kBadgeWarningText,
      ),
      MoveOutcome.rejected => (
        t.movement.outcomeRejected(reason: reason ?? ''),
        AppColors.kDanger,
      ),
    };
    return Center(
      child: Padding(
        padding: AppInsets.all24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: SemiboldTextStyles().semiboldInter16.copyWith(
                color: color,
              ),
            ),
            AppBoxes.kHeight24,
            FilledButton(
              onPressed: onDone,
              child: Text(t.movement.outcomeDone),
            ),
          ],
        ),
      ),
    );
  }
}
