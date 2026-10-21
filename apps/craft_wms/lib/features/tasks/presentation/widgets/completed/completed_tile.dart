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
import '../../../data/tasks_models.dart';
import '../common/task_format.dart';

/// Запись ленты «Завершённые»: задание целиком — номер и вид, основание, исполнители, время.
class CompletedTile extends StatelessWidget {
  const CompletedTile({super.key, required this.task, required this.onTap});

  final CompletedTask task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final executors = task.executors.map((u) => u.fullName).join(', ');
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
                    taskKindLabel(task.kind),
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(t.tasks.number(number: task.number), style: muted),
                  Text(
                    supplierBasis(task.supplier, kind: task.kind),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (executors.isNotEmpty) Text(executors, style: muted),
                  Text(t.tasks.sessions(count: task.sessions), style: muted),
                ],
              ),
            ),
            AppBoxes.kWidth8,
            Text(timeOfDay(task.completedAtTime), style: muted),
          ],
        ),
      ),
    );
  }
}
