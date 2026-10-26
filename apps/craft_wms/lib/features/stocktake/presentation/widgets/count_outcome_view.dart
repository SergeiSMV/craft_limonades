import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../bloc/stocktake_count_cubit.dart';

/// Итог подсчёта ячейки: проведён, ушёл в очередь, отклонён. Одна кнопка — к ячейкам.
class CountOutcomeView extends StatelessWidget {
  const CountOutcomeView({
    super.key,
    required this.outcome,
    required this.reason,
    required this.onDone,
  });

  final CountOutcome outcome;
  final String? reason;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (outcome) {
      CountOutcome.posted => (
        t.stocktake.outcomePosted,
        AppColors.kBadgeSuccessText,
      ),
      CountOutcome.queued => (
        t.stocktake.outcomeQueued,
        AppColors.kBadgeWarningText,
      ),
      CountOutcome.rejected => (
        t.stocktake.outcomeRejected(reason: reason ?? ''),
        AppColors.kDanger,
      ),
    };
    return Padding(
      padding: AppInsets.all16,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: SemiboldTextStyles().semiboldInter16.copyWith(
                  color: color,
                ),
              ),
            ),
          ),
          NeumorphicActionStack(
            buttons: [
              NeumorphicActionButton(
                label: t.stocktake.outcomeDone,
                icon: MdiIcons.arrowLeft,
                onPressed: onDone,
              ),
            ],
          ),
          AppBoxes.kHeight8,
        ],
      ),
    );
  }
}
