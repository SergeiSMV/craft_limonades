import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/semibold_text.dart';

/// Выпуклая кнопка-строка шапки — как шапка ячейки во «Вводе остатков»: приёмка (общий список
/// и страница короба) и короб прохода ввода остатков (ADHOC-46).
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.onPressed,
    required this.text,
    required this.icon,
    this.color,
  });

  final VoidCallback onPressed;
  final String text;
  final IconData icon;

  /// Цвет текста и иконки; `null` — обычный цвет шапки.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.kSidebarHover;
    return NeumorphicButton(
      onPressed: onPressed,
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
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SemiboldTextStyles().semiboldInter14.copyWith(
                color: color,
              ),
            ),
          ),
          AppBoxes.kWidth8,
          Icon(icon, size: AppSizes.kIcon25, color: color),
        ],
      ),
    );
  }
}

/// Квадратная выпуклая кнопка-иконка шапки — как кнопка отмены во «Вводе остатков».
class BarIconButton extends StatelessWidget {
  const BarIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.color,
  });

  final VoidCallback onPressed;
  final IconData icon;

  /// Цвет иконки; `null` — обычный цвет шапки.
  final Color? color;

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
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      padding: AppInsets.all12,
      child: Icon(
        icon,
        color: color ?? AppColors.kSidebarHover,
        size: AppSizes.kIcon20,
      ),
    );
  }
}
