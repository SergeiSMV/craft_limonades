import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/putaway_models.dart';
import '../../../../core/utils/doc_number.dart';

/// Итог сеанса: проведён, ушёл в очередь, отклонён. Одна кнопка — вернуться к заданию.
class PutawayOutcomeView extends StatelessWidget {
  const PutawayOutcomeView({
    super.key,
    required this.outcome,
    required this.reason,
    required this.onDone,
    this.onFix,
  });

  final PutawayOutcome outcome;
  final String? reason;
  final VoidCallback onDone;

  /// Вернуть отклонённый сеанс в правку (ADHOC-41); `null` — исправлять нечего.
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (outcome) {
      PutawayOutcome.posted => (
        t.putaway.outcomePosted,
        AppColors.kBadgeSuccessText,
      ),
      PutawayOutcome.queued => (
        t.putaway.outcomeQueued,
        AppColors.kBadgeWarningText,
      ),
      PutawayOutcome.rejected => (
        t.putaway.outcomeRejected(reason: reason ?? ''),
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
            if (outcome == PutawayOutcome.rejected && onFix != null) ...[
              FilledButton(onPressed: onFix, child: Text(t.putaway.outcomeFix)),
              AppBoxes.kHeight12,
              OutlinedButton(
                onPressed: onDone,
                child: Text(t.putaway.outcomeDone),
              ),
            ] else
              FilledButton(
                onPressed: onDone,
                child: Text(t.putaway.outcomeDone),
              ),
          ],
        ),
      ),
    );
  }
}

/// На терминале не завершено размещение по другому заданию: отбросить его или вернуться.
class ForeignDraftView extends StatelessWidget {
  const ForeignDraftView({
    super.key,
    required this.number,
    required this.onDiscard,
    required this.onBack,
  });

  final int number;
  final VoidCallback onDiscard;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppInsets.all24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.putaway.foreignDraftTitle,
              style: SemiboldTextStyles().semiboldInter16,
            ),
            AppBoxes.kHeight8,
            Text(
              t.putaway.foreignDraftBody(number: docNumber(DocKind.task, number)),
              textAlign: TextAlign.center,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
            AppBoxes.kHeight24,
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onBack,
                    child: Text(t.putaway.foreignDraftBack),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: onDiscard,
                    child: Text(t.putaway.foreignDraftDiscard),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
