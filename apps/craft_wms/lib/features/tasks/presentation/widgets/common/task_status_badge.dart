import 'package:flutter/material.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/tasks_models.dart';

/// Пометка статуса задания: «новое», «в работе», «выполнено».
class TaskStatusBadge extends StatelessWidget {
  const TaskStatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (status) {
      TaskStatus.inProgress => (
        t.tasks.statusInProgress,
        AppColors.kBadgeWarningBg,
        AppColors.kBadgeWarningText,
      ),
      TaskStatus.done => (
        t.tasks.statusDone,
        AppColors.kBadgeSuccessBg,
        AppColors.kBadgeSuccessText,
      ),
      _ => (
        t.tasks.statusNew,
        AppColors.kBadgeInfoBg,
        AppColors.kBadgeInfoText,
      ),
    };
    return Container(
      padding: AppInsets.badge,
      decoration: BoxDecoration(color: bg, borderRadius: AppBorders.kPill),
      child: Text(
        label,
        style: SemiboldTextStyles().semiboldInter12.copyWith(color: fg),
      ),
    );
  }
}
