import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/load_unit/box_code.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../data/tasks_models.dart';
import '../common/task_format.dart';

/// Позиция задания: короб с составом либо россыпь с партией и остатком (P5-02-1).
///
/// Выпуклая неоморфная плашка и шрифты — как у товара во вкладке «Товары» и в содержимом
/// ячейки и короба (ADHOC-21): одни и те же короба и товары не должны выглядеть по-разному
/// в разных разделах. Касание — карточка короба или карточка остатков товара. Размещённое
/// приглушено и отмечено галочкой — оно ещё видно, но работы по нему нет; открыть его можно.
class TaskItemTile extends StatelessWidget {
  const TaskItemTile({super.key, required this.item, required this.onTap});

  final TaskItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = RegularTextStyles().regularInter14.copyWith(
      height: 1.2,
      color: item.placed ? AppColors.kTextMuted : AppColors.kTextMain,
    );
    final muted = RegularTextStyles().regularInter10.copyWith(
      color: AppColors.kTextMuted,
    );
    return NeumorphicButton(
      onPressed: onTap,
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
            item.placed
                ? MdiIcons.checkCircle
                : item.isBox
                ? MdiIcons.packageVariantClosed
                : MdiIcons.cubeOutline,
            size: AppSizes.kIcon24,
            color: item.placed
                ? AppColors.kBadgeSuccessText
                : AppColors.kPlacePin,
          ),
          AppBoxes.kWidth12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: item.isBox ? _box(title, muted) : _loose(title, muted),
            ),
          ),
          if (item.placed) ...[
            AppBoxes.kWidth8,
            Text(
              item.problemId != null ? t.tasks.shipped : t.tasks.placed,
              style: muted,
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _box(TextStyle title, TextStyle muted) => [
    Text(
      t.tasks.box(code: boxCode(item.loadUnitId!, czCode: item.czCode)),
      style: title,
    ),
    // Каждый товар короба — наименование, партия и количество своими строками.
    for (final c in item.contents) ...[
      Text(c.good.name, style: muted),
      Text(t.tasks.batch(date: batchDate(c.productionDate)), style: muted),
      Text(
        t.tasks.qtyLine(qty: qtyText(c.qty), uom: c.good.uom),
        style: muted,
      ),
    ],
    ..._cell(muted),
  ];

  /// Где позиция возврата лежит сейчас (ADHOC-31); у размещения ячейки нет.
  List<Widget> _cell(TextStyle muted) => [
    if (item.cell.isNotEmpty) Text(t.tasks.cell(cell: item.cell), style: muted),
  ];

  List<Widget> _loose(TextStyle title, TextStyle muted) => [
    Text(item.good?.name ?? '', style: title),
    Text(
      t.tasks.batch(date: batchDate(item.productionDate ?? '')),
      style: muted,
    ),
    // У возврата позиция отгружается целиком — «осталось из» там не к чему (ADHOC-31).
    Text(
      item.problemId != null
          ? t.tasks.qtyLine(qty: qtyText(item.qty), uom: item.good?.uom ?? '')
          : t.tasks.remaining(
              qty: qtyText(item.remaining),
              total: qtyText(item.qty),
              uom: item.good?.uom ?? '',
            ),
      style: muted,
    ),
    ..._cell(muted),
  ];
}
