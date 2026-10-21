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
import '../../../domain/problem_records.dart';
import 'record_format.dart';

/// Запись списка проблем — «Текущие» (ADHOC-35) и «Завершённые» (ADHOC-34): где проблема
/// сейчас (ожидает отправки, ждёт решения, что сделано), что помечали, место, причина; у
/// открытой — кто зафиксировал. Каждое своей строкой; справа — время решения или фиксации. Вид — как у записи «Завершённых» заданий и перемещений.
class ProblemRecordTile extends StatelessWidget {
  const ProblemRecordTile({
    super.key,
    required this.problem,
    required this.onTap,
  });

  final ProblemRecord problem;
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
            // Решённая — галочка; открытая и своя неотправленная — часы: ещё в работе.
            Icon(
              problem.isOpen
                  ? MdiIcons.clockOutline
                  : MdiIcons.checkCircleOutline,
              size: AppSizes.kIcon24,
              color: problem.isOpen
                  ? AppColors.kBadgeWarningText
                  : AppColors.kBadgeSuccessText,
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
                  if (problem.isOpen && problem.createdBy.isNotEmpty)
                    Text(
                      t.problems.createdByLine(name: problem.createdBy),
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
