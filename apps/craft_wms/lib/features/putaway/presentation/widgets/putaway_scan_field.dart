import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле скана размещения: в режиме «клавиатуры» сканер DT50 печатает код сюда. Экранная
/// клавиатура не показывается — тот же приём, что у приёмки.
class PutawayScanField extends StatelessWidget {
  const PutawayScanField({
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
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
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
          filled: true,
          fillColor: AppColors.kNeumorphicBg,
          prefixIcon: Padding(
            padding: AppInsets.left10,
            child: Icon(
              MdiIcons.barcodeScan,
              color: AppColors.kSidebarHover,
              size: AppSizes.kIcon24,
            ),
          ),
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kSidebarHover,
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
