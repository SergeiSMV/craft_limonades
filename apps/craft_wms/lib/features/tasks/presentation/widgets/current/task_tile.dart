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

/// Текущее задание в списке — стандарт для любого вида задания, три строки:
///
///   Размещение                    [в работе]
///   №2 · 05.10.2026 13:58
///   Автор: автоматически
///
/// Остальное (основание, позиции, кто взял) — в карточке. Статус стоит в строке вида: она
/// короткая, и пометка не выталкивает текст на перенос, как было с номером в заголовке.
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
              task.kind == TaskKind.supplierReturn
                  ? MdiIcons.truckDeliveryOutline
                  : MdiIcons.forklift,
              size: AppSizes.kIcon25,
              color: AppColors.kTileTasks,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          taskKindLabel(task.kind),
                          style: SemiboldTextStyles().semiboldInter14.copyWith(
                            color: AppColors.kSidebarHover,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TaskStatusBadge(status: task.status),
                    ],
                  ),
                  Text(t.tasks.number(number: task.number), style: muted),
                  Text(
                    t.tasks.createdLine(created: fullDateTime(task.createdAt)),
                    style: muted,
                  ),
                  // Возврат — кому везём (ADHOC-31): без поставщика задания не различить.
                  if (task.kind == TaskKind.supplierReturn)
                    Text(
                      t.tasks.returnSupplier(supplier: task.supplier),
                      style: muted,
                    ),
                  Text(taskAuthor(task), style: muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
