import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';

/// Выпуклая неоморфная плашка-кнопка строки: наименование, подпись под ним, число справа
/// (P6-04). Вид — как у товара в «Остатках» (вкладка «Товары», содержимое короба и ячейки):
/// выбираемая позиция — это кнопка, и выглядит она кнопкой.
class NeumorphicLineTile extends StatelessWidget {
  const NeumorphicLineTile({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  final String title;
  final String? subtitle;

  /// Число справа — количество.
  final String? trailing;
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
                  title,
                  style: RegularTextStyles().regularInter14.copyWith(
                    height: 1.2,
                    color: AppColors.kTextMain,
                  ),
                ),
                if (subtitle case final s?)
                  Text(
                    s,
                    style: RegularTextStyles().regularInter10.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing case final tr?) ...[
            AppBoxes.kWidth12,
            Text(
              tr,
              style: SemiboldTextStyles().semiboldInter16.copyWith(
                color: AppColors.kTextMain,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
