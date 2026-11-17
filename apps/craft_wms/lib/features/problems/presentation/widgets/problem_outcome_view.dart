import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/problem_state.dart';

/// Итог фиксации: проведена, ушла в очередь, отклонена. «Ещё проблема» - следующая, без
/// выхода в меню: брак обычно находят не по одной позиции.
class ProblemOutcomeView extends StatelessWidget {
  const ProblemOutcomeView({
    super.key,
    required this.outcome,
    required this.reason,
    required this.onNext,
    required this.onDone,
  });

  final ProblemOutcome outcome;
  final String? reason;
  final VoidCallback onNext;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (outcome) {
      ProblemOutcome.posted => (
        t.problems.outcomePosted,
        AppColors.kBadgeSuccessText,
      ),
      ProblemOutcome.queued => (
        t.problems.outcomeQueued,
        AppColors.kBadgeWarningText,
      ),
      ProblemOutcome.rejected => (
        t.problems.outcomeRejected(reason: reason ?? ''),
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
            FilledButton(onPressed: onNext, child: Text(t.problems.next)),
            AppBoxes.kHeight8,
            TextButton(onPressed: onDone, child: Text(t.problems.done)),
          ],
        ),
      ),
    );
  }
}
