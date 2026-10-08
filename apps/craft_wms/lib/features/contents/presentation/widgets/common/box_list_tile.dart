import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/printer/load_unit_label.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../domain/contents_entities.dart';
import '../common/pending_mark.dart';

/// Короб в списке — во вкладке «Короба» и на экране «Ячейка» (P5-05-1): та же выпуклая
/// неоморфная плашка и те же шрифты, что у товара во вкладке «Товары», плюс иконка короба —
/// она отличает короб от товара в одном списке. Касание — карточка короба.
///
/// Короткий код, а не идентификатор: кладовщик сверяет его с наклейкой на коробе глазами.
class BoxListTile extends StatelessWidget {
  const BoxListTile({
    super.key,
    required this.loadUnit,
    required this.onTap,
    this.showCell = true,
  });

  final LoadUnitView loadUnit;
  final VoidCallback onTap;

  /// Писать ячейку в подписи. На экране «Ячейка» не пишем — она в шапке.
  final bool showCell;

  @override
  Widget build(BuildContext context) {
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
            MdiIcons.packageVariantClosed,
            size: AppSizes.kIcon24,
            color: AppColors.kPlacePin,
          ),
          AppBoxes.kWidth12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.contents.boxCode(
                    code: LoadUnitLabel(loadUnit.id).shortCodeFormatted,
                  ),
                  style: RegularTextStyles().regularInter14.copyWith(
                    height: 1.2,
                    color: AppColors.kTextMain,
                  ),
                ),
                Text(
                  [
                    if (showCell) loadUnit.cellAddress ?? t.contents.notPlaced,
                    t.contents.positions(count: loadUnit.lines.length),
                  ].join(' · '),
                  style: RegularTextStyles().regularInter10.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
                if (!loadUnit.live)
                  Text(
                    t.contents.notLive,
                    style: RegularTextStyles().regularInter10.copyWith(
                      color: AppColors.kDanger,
                    ),
                  ),
                if (loadUnit.pending) const PendingMark(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
