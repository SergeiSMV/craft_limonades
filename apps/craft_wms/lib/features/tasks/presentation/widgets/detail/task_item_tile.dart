import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../data/tasks_models.dart';
import '../common/task_format.dart';

/// Позиция задания: короб с составом либо россыпь с партией и остатком. Размещённое
/// приглушено и отмечено галочкой — оно ещё видно, но работы по нему нет.
class TaskItemTile extends StatelessWidget {
  const TaskItemTile({super.key, required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final title = SemiboldTextStyles().semiboldInter14.copyWith(
      color: item.placed ? AppColors.kTextMuted : AppColors.kTextMain,
    );
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return Padding(
      padding: AppInsets.v4,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            item.placed
                ? MdiIcons.checkCircle
                : item.isBox
                ? MdiIcons.packageVariantClosed
                : MdiIcons.cubeOutline,
            size: AppSizes.kIcon20,
            color: item.placed
                ? AppColors.kBadgeSuccessText
                : AppColors.kPrimary,
          ),
          AppBoxes.kWidth8,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: item.isBox ? _box(title, muted) : _loose(title, muted),
            ),
          ),
          if (item.placed) Text(t.tasks.placed, style: muted),
        ],
      ),
    );
  }

  List<Widget> _box(TextStyle title, TextStyle muted) => [
    Text(
      t.tasks.box(code: LoadUnitLabel(item.loadUnitId!).shortCodeFormatted),
      style: title,
    ),
    for (final c in item.contents)
      Text(
        '${c.good.name} · ${t.tasks.batch(date: batchDate(c.productionDate))} · '
        '${qtyText(c.qty)} ${c.good.uom}',
        style: muted,
      ),
  ];

  List<Widget> _loose(TextStyle title, TextStyle muted) => [
    Text(item.good?.name ?? '', style: title),
    Text(
      '${t.tasks.batch(date: batchDate(item.productionDate ?? ''))} · '
      '${t.tasks.remaining(qty: qtyText(item.remaining), total: qtyText(item.qty), uom: item.good?.uom ?? '')}',
      style: muted,
    ),
  ];
}
