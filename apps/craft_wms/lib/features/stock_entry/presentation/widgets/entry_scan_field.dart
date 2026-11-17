import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле скана «Ввода остатков» - общее для ячейки и короба прохода (ADHOC-46).
///
/// Ввод только сканером (аппаратная «клавиатура» DT50): софт-клавиатуру не показываем, чтобы
/// после «Добавить»/скана она не всплывала. Касание открывает ручной выбор товара.
class EntryScanField extends StatelessWidget {
  const EntryScanField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onTap,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: 3,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
      ),
      child: TextField(
        onTap: onTap,
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
          suffixIcon: Padding(
            padding: AppInsets.right10,
            child: Icon(
              MdiIcons.viewList,
              color: AppColors.kSidebarHover,
              size: AppSizes.kIcon25,
            ),
          ),
          hintText: t.stockEntry.scanGood,
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
