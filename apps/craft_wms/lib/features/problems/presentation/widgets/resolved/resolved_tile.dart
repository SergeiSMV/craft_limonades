import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../domain/resolved_problems.dart';
import 'resolved_format.dart';

/// Запись ленты «Завершённые» проблем (ADHOC-34): что сделано по решению, что помечали, место
/// и причина — каждое своей строкой, время решения. Вид — как у записи «Завершённых» заданий и перемещений.
class ResolvedTile extends StatelessWidget {
  const ResolvedTile({super.key, required this.problem, required this.onTap});

  final ResolvedProblem problem;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.bottom8,
      child: NeumorphicButton(
        onPressed: onTap,
        padding: AppInsets.all12,
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: 2,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              MdiIcons.checkCircleOutline,
              size: AppSizes.kIcon24,
              color: AppColors.kBadgeSuccessText,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    outcomeLabel(problem),
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(
                    subjectLabel(problem),
                    style: RegularTextStyles().regularInter14.copyWith(
                      color: AppColors.kTextMain,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    t.problems.placeLine(place: problem.cellAddress),
                    style: muted,
                  ),
                  Text(
                    t.problems.reasonLine(
                      reason: reasonLabelOf(problem.reason),
                    ),
                    style: muted,
                  ),
                ],
              ),
            ),
            AppBoxes.kWidth8,
            Text(timeOfDay(problem.resolvedAtTime), style: muted),
          ],
        ),
      ),
    );
  }
}
