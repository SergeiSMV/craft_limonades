import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/regular_text.dart';

/// Поле скана потоков «взял → положил» (размещение, перемещение): в режиме «клавиатуры»
/// сканер DT50 печатает код сюда. Экранная клавиатура не показывается — тот же приём, что
/// у приёмки.
///
/// Вид — общий для полей приложения («Остатки», «Ввод остатков»): вдавленная плашка, иконка
/// и подсказка приглушёнными цветами, подсказка шрифтом 16.
class ScanField extends StatelessWidget {
  const ScanField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: -2,
        shape: NeumorphicShape.flat,
      ),
      child: TextField(
        showCursor: false,
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        keyboardType: TextInputType.none,
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: AppInsets.right2 + AppInsets.left12,
            child: Icon(
              MdiIcons.barcode,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter16.copyWith(
            color: AppColors.kBorderDashed,
          ),
          border: const OutlineInputBorder(
            borderRadius: AppBorders.kCircular8,
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
      ),
    );
  }
}
