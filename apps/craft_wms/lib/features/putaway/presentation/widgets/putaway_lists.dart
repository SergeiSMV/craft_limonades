import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/printer/load_unit_label.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../../tasks/presentation/widgets/common/task_format.dart';
import '../bloc/putaway_cubit.dart';
import '../bloc/putaway_models.dart';
import 'putaway_format.dart';

/// «Осталось разместить» и «Размещено в этом заходе».
///
/// Позицию можно взять и касанием, без скана: ярлык короба бывает затёрт, у товара может
/// не оказаться штрихкода. Скан остаётся основным путём — он не даёт взять не то.
class PutawayLists extends StatelessWidget {
  const PutawayLists({
    super.key,
    required this.state,
    required this.onPickBox,
    required this.onPickLoose,
    required this.onRemoveLine,
  });

  final PutawayState state;
  final ValueChanged<TaskItem> onPickBox;
  final ValueChanged<TaskItem> onPickLoose;
  final ValueChanged<PutawayLine> onRemoveLine;

  @override
  Widget build(BuildContext context) {
    final section = SemiboldTextStyles().semiboldInter16;
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    final boxes = state.openBoxes;
    final loose = state.openLoose;
    return ListView(
      padding: AppInsets.h8,
      children: [
        Text(t.putaway.leftSection, style: section),
        AppBoxes.kHeight8,
        if (boxes.isEmpty && loose.isEmpty)
          Text(t.putaway.leftEmpty, style: muted),
        for (final b in boxes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              MdiIcons.packageVariantClosed,
              size: AppSizes.kIcon24,
              color: AppColors.kPrimary,
            ),
            title: Text(
              t.putaway.box(
                code: LoadUnitLabel(b.loadUnitId!).shortCodeFormatted,
              ),
              style: SemiboldTextStyles().semiboldInter14,
            ),
            subtitle: Text(
              b.contents
                  .map(
                    (c) => '${c.good.name} · ${qtyText(c.qty)} ${c.good.uom}',
                  )
                  .join('\n'),
              style: muted,
            ),
            onTap: () => onPickBox(b),
          ),
        for (final (item, left) in loose)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              MdiIcons.cubeOutline,
              size: AppSizes.kIcon24,
              color: AppColors.kPrimary,
            ),
            title: Text(
              item.good?.name ?? '',
              style: SemiboldTextStyles().semiboldInter14,
            ),
            subtitle: Text(
              t.putaway.looseLeft(
                date: batchDate(item.productionDate ?? ''),
                qty: fmtQty(left),
                uom: item.good?.uom ?? '',
              ),
              style: muted,
            ),
            onTap: () => onPickLoose(item),
          ),
        if (state.lines.isNotEmpty) ...[
          AppBoxes.kHeight16,
          Text(t.putaway.doneSection, style: section),
          AppBoxes.kHeight8,
          for (final line in state.lines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                MdiIcons.checkCircle,
                size: AppSizes.kIcon24,
                color: AppColors.kBadgeSuccessText,
              ),
              title: Text(
                pickTitle(line.pick),
                style: SemiboldTextStyles().semiboldInter14,
              ),
              subtitle: Text(
                t.putaway.lineTo(cell: line.cell.address),
                style: muted,
              ),
              trailing: IconButton(
                tooltip: t.putaway.removeLine,
                icon: Icon(MdiIcons.close, color: AppColors.kTextMuted),
                onPressed: () => onRemoveLine(line),
              ),
            ),
        ],
        AppBoxes.kHeight16,
      ],
    );
  }
}
