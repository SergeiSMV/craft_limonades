import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../domain/movement_models.dart';
import 'move_format.dart';

/// «Перемещено в этом сеансе»: что, откуда и куда. Строку можно убрать — перемещено не туда.
class MoveLinesList extends StatelessWidget {
  const MoveLinesList({super.key, required this.lines, required this.onRemove});

  final List<MoveLine> lines;
  final ValueChanged<MoveLine> onRemove;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return ListView(
      padding: AppInsets.h8,
      children: [
        Text(
          t.movement.linesSection,
          style: SemiboldTextStyles().semiboldInter16,
        ),
        AppBoxes.kHeight8,
        if (lines.isEmpty) Text(t.movement.linesEmpty, style: muted),
        for (final l in lines.reversed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              l.isWholeBox
                  ? MdiIcons.packageVariantClosed
                  : MdiIcons.swapHorizontal,
              size: AppSizes.kIcon24,
              color: AppColors.kPrimary,
            ),
            title: Text(
              l.isWholeBox
                  ? t.movement.lineBox(code: boxCode(l.loadUnitId!))
                  : goodsLabel(l.good!, l.productionDate!, l.qty ?? 0),
              style: RegularTextStyles().regularInter14,
            ),
            subtitle: Text(
              t.movement.lineRoute(
                from: l.isWholeBox ? l.from.cellAddress : placeLabel(l.from),
                to: placeLabel(l.to),
              ),
              style: muted,
            ),
            trailing: IconButton(
              tooltip: t.movement.removeLine,
              icon: Icon(MdiIcons.close, size: AppSizes.kIcon18),
              onPressed: () => onRemove(l),
            ),
          ),
      ],
    );
  }
}
