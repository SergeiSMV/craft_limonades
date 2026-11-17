import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/regular_text.dart';

/// Вариант выбора - выпуклая неоморфная кнопка; выбранный отмечен красной точкой справа.
///
/// Тот же вид, что у вариантов фильтра «Остатков»: выбор из нескольких значений в приложении
/// выглядит одинаково, а не стандартными чипами Material.
class NeumorphicChoice extends StatelessWidget {
  const NeumorphicChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return NeumorphicButton(
      onPressed: onPressed,
      padding: AppInsets.all8,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 2,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: RegularTextStyles().regularInter14),
          if (selected) ...[
            AppBoxes.kWidth8,
            Container(
              width: AppSizes.kDotMark,
              height: AppSizes.kDotMark,
              decoration: const BoxDecoration(
                color: AppColors.kDanger,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
