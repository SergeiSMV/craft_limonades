import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';

/// Квадратная неоморфная кнопка-иконка портала (ADHOC-25).
///
/// Что: действие строки списка — скачать, история, отметить выполненным; выход и меню в шапке.
/// Как: цвет кнопки — фон рабочей области портала, поэтому кнопка «выдавлена» из него, а не
///      лежит поверх; тени — общие токены неоморфизма. Пока действие идёт ([busy]), вместо
///      иконки — индикатор, и кнопка не нажимается: второе нажатие запустило бы его ещё раз.
class NeumorphicIconButton extends StatelessWidget {
  const NeumorphicIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Действие идёт — индикатор вместо иконки.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: NeumorphicButton(
        onPressed: busy ? null : onPressed,
        padding: EdgeInsets.zero,
        style: NeumorphicStyle(
          color: AppColors.kBg,
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          depth: AppSizes.kNeumorphicDepth,
          shape: NeumorphicShape.flat,
          // Скруглённый квадрат, а не круг (ADHOC-25): в тон плашкам и полям портала.
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
        ),
        child: SizedBox(
          width: AppSizes.kIcon40,
          height: AppSizes.kIcon40,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: AppSizes.kIcon18,
                    height: AppSizes.kIcon18,
                    child: CircularProgressIndicator(
                      strokeWidth: AppSizes.kIcon2,
                    ),
                  )
                : Icon(
                    icon,
                    size: AppSizes.kIcon20,
                    color: AppColors.kTextMuted,
                  ),
          ),
        ),
      ),
    );
  }
}
