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
import '../common/task_status_badge.dart';

/// Текущее задание в списке: номер и вид, основание, сколько позиций осталось, статус.
/// Выпуклая плитка — вход в карточку задания, как короб в приёмке.
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task, required this.onTap});

  final WarehouseTask task;
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
          depth: 3,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        child: Row(
          children: [
            Icon(
              MdiIcons.forklift,
              size: AppSizes.kIcon25,
              color: AppColors.kTileTasks,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${t.tasks.number(number: task.number)} · ${taskKindLabel(task.kind)}',
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(
                    '${taskBasis(task.supplier)} · ${shortDateTime(task.receivedAt ?? task.createdAt)}',
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(t.tasks.openItems(count: task.openItems), style: muted),
                ],
              ),
            ),
            AppBoxes.kWidth8,
            TaskStatusBadge(status: task.status),
          ],
        ),
      ),
    );
  }
}
