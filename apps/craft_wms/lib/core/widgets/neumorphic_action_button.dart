import 'package:flutter/material.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart'
    show NeumorphicButton, NeumorphicStyle, NeumorphicShape, NeumorphicBoxShape;

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/regular_text.dart';

/// Выпуклая неоморфная кнопка действия во всю ширину: подпись и иконка (P6-04).
///
/// Плашка — как у «Перепечатать ярлык» в карточке короба; подпись — как у короба в «Остатках»
/// (обычный Inter 14), иконка — цветом подписи. Кнопки ставятся стопкой — на ширине ТСД
/// в строку несколько действий не помещаются.
class NeumorphicActionButton extends StatelessWidget {
  const NeumorphicActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return NeumorphicButton(
      onPressed: onPressed,
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
      ),
      padding: AppInsets.all12,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              style: RegularTextStyles().regularInter14.copyWith(
                height: 1.2,
                color: AppColors.kTextMain,
              ),
            ),
          ),
          AppBoxes.kWidth12,
          Icon(icon, size: AppSizes.kIcon20, color: AppColors.kTextMain),
        ],
      ),
    );
  }
}

/// Стопка кнопок действий с промежутком между ними.
class NeumorphicActionStack extends StatelessWidget {
  const NeumorphicActionStack({super.key, required this.buttons});

  final List<NeumorphicActionButton> buttons;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) AppBoxes.kHeight8,
          buttons[i],
        ],
      ],
    );
  }
}
