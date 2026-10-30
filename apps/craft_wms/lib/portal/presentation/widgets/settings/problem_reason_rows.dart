import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/problems/problem_reasons.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../data/problems_repository.dart';
import '../ui/portal_badge.dart';
import '../ui/portal_button.dart';

/// Строки справочника причин проблем и вариантов решения (ADHOC-55).

/// Действие варианта решения — что делает программа.
String resolutionActionLabel(String action) => switch (action) {
  ProblemDecision.writeOff => t.portal.problemReasons.actionWriteOff,
  ProblemDecision.place => t.portal.problemReasons.actionPlace,
  ProblemDecision.supplierReturn =>
    t.portal.problemReasons.actionSupplierReturn,
  ProblemDecision.regrade => t.portal.problemReasons.actionRegrade,
  _ => action,
};

/// Строка причины: название, отметки и варианты решения; изменить, выключить или включить.
/// Системную причину не выключить — кнопки нет.
class ProblemReasonRow extends StatelessWidget {
  const ProblemReasonRow({
    super.key,
    required this.reason,
    required this.variantNames,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
  });

  final ProblemReason reason;

  /// Названия вариантов причины, в порядке справочника.
  final List<String> variantNames;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final r = reason;
    final tr = t.portal.problemReasons;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.cardRow,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  runSpacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      r.name,
                      style: SemiboldTextStyles().semiboldInter14.copyWith(
                        color: r.isActive
                            ? AppColors.kTextMain
                            : AppColors.kTextMuted,
                      ),
                    ),
                    if (r.isSystem) PortalBadge(tr.markSystem),
                    if (!r.manual) PortalBadge(tr.markProgram),
                    if (r.commentRequired)
                      PortalBadge(
                        tr.markComment,
                        tone: PortalBadgeTone.success,
                      ),
                    if (!r.isActive)
                      PortalBadge(
                        tr.markInactive,
                        tone: PortalBadgeTone.warning,
                      ),
                  ],
                ),
                AppBoxes.kHeight4,
                Text(
                  variantNames.isEmpty
                      ? tr.noResolutionsLine
                      : tr.resolutionsLine(names: variantNames.join(', ')),
                  style: muted,
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          PortalIconButton(
            icon: Icons.edit_outlined,
            tooltip: tr.edit,
            busy: busy,
            onPressed: onEdit,
          ),
          if (!r.isSystem) ...[
            AppBoxes.kWidth4,
            PortalIconButton(
              icon: r.isActive
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              tooltip: r.isActive ? tr.hide : tr.show,
              busy: busy,
              onPressed: onToggle,
            ),
          ],
        ],
      ),
    );
  }
}

/// Строка варианта решения: название и действие; переименовать, выключить или включить.
class ResolutionVariantRow extends StatelessWidget {
  const ResolutionVariantRow({
    super.key,
    required this.variant,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
  });

  final ResolutionVariant variant;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final v = variant;
    final tr = t.portal.problemReasons;
    return Padding(
      padding: AppInsets.cardRow,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSizes.kChipSpacing,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      v.name,
                      style: SemiboldTextStyles().semiboldInter14.copyWith(
                        color: v.isActive
                            ? AppColors.kTextMain
                            : AppColors.kTextMuted,
                      ),
                    ),
                    if (!v.isActive)
                      PortalBadge(
                        tr.markVariantInactive,
                        tone: PortalBadgeTone.warning,
                      ),
                  ],
                ),
                AppBoxes.kHeight4,
                Text(
                  tr.actionLine(action: resolutionActionLabel(v.action)),
                  style: RegularTextStyles().regularInter12.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
              ],
            ),
          ),
          AppBoxes.kWidth8,
          PortalIconButton(
            icon: Icons.edit_outlined,
            tooltip: tr.edit,
            busy: busy,
            onPressed: onEdit,
          ),
          AppBoxes.kWidth4,
          PortalIconButton(
            icon: v.isActive
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            tooltip: v.isActive ? tr.hide : tr.show,
            busy: busy,
            onPressed: onToggle,
          ),
        ],
      ),
    );
  }
}
