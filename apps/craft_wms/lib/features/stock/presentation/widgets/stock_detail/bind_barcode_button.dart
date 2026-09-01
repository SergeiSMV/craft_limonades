import 'package:flutter/material.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart'
    show NeumorphicButton, NeumorphicStyle, NeumorphicShape, NeumorphicBoxShape;

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/semibold_text.dart';

/// Кнопка «Привязать штрихкод +» во всю ширину (P-FS-17).
///
/// Стоит либо вместо секции ШК, когда у товара не привязано ни одного кода, либо под списком
/// внутри раскрытой секции.
class BindBarcodeButton extends StatelessWidget {
  const BindBarcodeButton({super.key, required this.onPressed});

  /// Открыть диалог привязки.
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
          Text(
            t.stockDetailScreen.bindBarcode,
            style: SemiboldTextStyles().semiboldInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
          AppBoxes.kWidth12,
          const Icon(
            Icons.add,
            size: AppSizes.kIcon20,
            color: AppColors.kTextMain,
          ),
        ],
      ),
    );
  }
}
