import 'package:flutter/material.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart'
    show NeumorphicButton, NeumorphicStyle, NeumorphicShape, NeumorphicBoxShape;
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/semibold_text.dart';

/// Кнопка «Перепечатать ярлык» во всю ширину (P5-05-1) — в стиле «Привязать штрихкод»
/// карточки товара. Пока идёт печать, вместо иконки крутилка и нажатие не принимается.
class ReprintButton extends StatelessWidget {
  const ReprintButton({super.key, required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return NeumorphicButton(
      onPressed: busy ? null : onPressed,
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
          Text(
            t.contents.reprint,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kWidth12,
          if (busy)
            const SizedBox(
              width: AppSizes.kIcon20,
              height: AppSizes.kIcon20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              MdiIcons.printer,
              size: AppSizes.kIcon20,
              color: AppColors.kTextMain,
            ),
        ],
      ),
    );
  }
}
