import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../bloc/supplier_return_cubit.dart';

/// Итог отгрузки: проведена, ушла в очередь, отклонена. Одна кнопка - вернуться к заданию.
class ReturnOutcomeView extends StatelessWidget {
  const ReturnOutcomeView({
    super.key,
    required this.outcome,
    required this.reason,
    required this.onDone,
  });

  final ReturnOutcome outcome;
  final String? reason;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (outcome) {
      ReturnOutcome.posted => (
        t.supplierReturn.outcomePosted,
        AppColors.kBadgeSuccessText,
      ),
      ReturnOutcome.queued => (
        t.supplierReturn.outcomeQueued,
        AppColors.kBadgeWarningText,
      ),
      ReturnOutcome.rejected => (
        t.supplierReturn.outcomeRejected(reason: reason ?? ''),
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
                label: t.supplierReturn.outcomeDone,
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
