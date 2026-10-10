import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/semibold_text.dart';

/// Неоморфная кнопка-пилюля с подписью для диалогов портала (ADHOC-25).
///
/// Что: действие диалога — «Отметить», «Закрыть».
/// Как: тот же приём, что у [NeumorphicIconButton] строк списка: кнопка цвета фона диалога
///      «выдавлена» из него. [accent] — главное действие диалога, его подпись выделена цветом
///      бренда; второстепенные — нейтральным.
class NeumorphicTextButton extends StatelessWidget {
  const NeumorphicTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.accent = false,
  });

  final String label;
  final VoidCallback onPressed;

  /// Главное действие диалога — подпись цветом бренда.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return NeumorphicButton(
      onPressed: onPressed,
      padding: AppInsets.h24v12,
      style: NeumorphicStyle(
        color: AppColors.kBg,
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        depth: AppSizes.kNeumorphicDepth,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kPill),
      ),
      child: Text(
        label,
        style: SemiboldTextStyles().semiboldInter14.copyWith(
          color: accent ? AppColors.kPrimary : AppColors.kTextSecondary,
        ),
      ),
    );
  }
}
