import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/utils/date_time_format.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../domain/contents_entities.dart';
import '../common/pending_mark.dart';

/// Товар в коробе или россыпью в ячейке (P5-05-1): выпуклая неоморфная плашка и шрифты, как
/// у товара во вкладке «Товары»; касание - карточка остатков этого товара.
class GoodLineTile extends StatelessWidget {
  const GoodLineTile({super.key, required this.line, required this.onTap});

  final ContentLine line;
  final VoidCallback onTap;

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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.goodName ?? t.contents.unknownGood,
                  style: RegularTextStyles().regularInter14.copyWith(
                    height: 1.2,
                    color: AppColors.kTextMain,
                  ),
                ),
                Text(
                  t.contents.batch(date: batchDate(line.productionDate)),
                  style: RegularTextStyles().regularInter10.copyWith(
                    color: AppColors.kTextMuted,
                  ),
                ),
                // «В сборке» (P9-06): взятое в короб отгрузки ещё числится в ячейке.
                if (line.inPicking > 0)
                  Text(
                    t.contents.inPicking(
                      total: fmtQty(line.qty),
                      picking: fmtQty(line.inPicking),
                      uom: line.uom ?? '',
                    ),
                    style: RegularTextStyles().regularInter10.copyWith(
                      color: AppColors.kBadgeWarningText,
                    ),
                  ),
                if (line.pending) const PendingMark(),
              ],
            ),
          ),
          AppBoxes.kWidth12,
          Text(
            fmtQty(line.qty),
            style: SemiboldTextStyles().semiboldInter16.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ],
      ),
    );
  }
}
