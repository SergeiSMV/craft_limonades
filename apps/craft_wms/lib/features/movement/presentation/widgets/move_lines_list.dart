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

/// «Перемещено в этом сеансе»: что, откуда и куда. Строку можно убрать - перемещено не туда.
///
/// Тот же список показывает и запись истории (ADHOC-28): там строки только для чтения
/// ([onRemove] = null), идут по порядку проведения ([newestFirst] = false) и под своим
/// заголовком - кладовщик видит историю теми же словами, что и свой сеанс.
class MoveLinesList extends StatelessWidget {
  const MoveLinesList({
    super.key,
    required this.lines,
    this.onRemove,
    this.title,
    this.newestFirst = true,
  });

  final List<MoveLine> lines;
  final ValueChanged<MoveLine>? onRemove;
  final String? title;
  final bool newestFirst;

  @override
  Widget build(BuildContext context) {
    final muted = RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    );
    return ListView(
      padding: AppInsets.h8,
      children: [
        Text(
          title ?? t.movement.linesSection,
          style: SemiboldTextStyles().semiboldInter16,
        ),
        AppBoxes.kHeight8,
        if (lines.isEmpty) Text(t.movement.linesEmpty, style: muted),
        for (final l in newestFirst ? lines.reversed : lines)
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
                  : goodsLabel(
                      l.good!,
                      l.productionDate!,
                      l.qty ?? 0,
                      warehouse: l.internalWarehouseName,
                    ),
              style: RegularTextStyles().regularInter14,
            ),
            subtitle: Text(
              t.movement.lineRoute(
                from: l.isWholeBox ? l.from.cellAddress : placeLabel(l.from),
                to: placeLabel(l.to),
              ),
              style: muted,
            ),
            trailing: onRemove == null
                ? null
                : IconButton(
                    tooltip: t.movement.removeLine,
                    icon: Icon(MdiIcons.close, size: AppSizes.kIcon18),
                    onPressed: () => onRemove!(l),
                  ),
          ),
      ],
    );
  }
}
