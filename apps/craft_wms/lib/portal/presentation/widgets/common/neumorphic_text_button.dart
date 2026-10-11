import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/semibold_text.dart';

/// Неоморфная кнопка с подписью (ADHOC-25): действия диалогов («Провести», «Закрыть»)
/// и строк таблицы документов («.xlsx», «Провести»).
///
/// Как: тот же приём, что у [NeumorphicIconButton]: кнопка цвета фона «выдавлена» из него,
/// скругление 12. [accent] — главное действие диалога, подпись цветом бренда; второстепенные —
/// нейтральным. [icon] — иконка перед подписью. Пока действие идёт ([busy]), вместо иконки —
/// индикатор, и кнопка не нажимается.
class NeumorphicTextButton extends StatelessWidget {
  const NeumorphicTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.accent = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback onPressed;

  /// Иконка перед подписью; `null` — только подпись.
  final IconData? icon;

  /// Главное действие диалога — подпись цветом бренда.
  final bool accent;

  /// Действие идёт — индикатор на месте иконки, кнопка не нажимается.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = accent ? AppColors.kPrimary : AppColors.kTextSecondary;
    return NeumorphicButton(
      onPressed: busy ? null : onPressed,
      padding: AppInsets.h16v10,
      style: NeumorphicStyle(
        color: AppColors.kBg,
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        depth: AppSizes.kNeumorphicDepth,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(
              dimension: AppSizes.kIcon18,
              child: CircularProgressIndicator(strokeWidth: AppSizes.kIcon2),
            )
          else if (icon != null)
            Icon(icon, size: AppSizes.kIcon18, color: AppColors.kTextMuted),
          if (busy || icon != null) AppBoxes.kWidth8,
          Text(
            label,
            style: SemiboldTextStyles().semiboldInter14.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
