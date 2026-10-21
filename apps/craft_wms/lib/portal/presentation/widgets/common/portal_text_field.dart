import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле ввода портала — вдавленная неоморфная плашка, как поле поиска документов (ADHOC-26).
/// Без рамок и заливки темы: поле — сама плашка.
class PortalTextField extends StatelessWidget {
  const PortalTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Neumorphic(
      style: NeumorphicStyle(
        color: AppColors.kNeumorphicBg,
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        depth: AppSizes.kNeumorphicInsetDepth,
        shape: NeumorphicShape.flat,
        boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
      ),
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        onSubmitted: onSubmitted,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
        cursorColor: AppColors.kTextMain,
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: AppInsets.searchBox,
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kSidebarMuted,
          ),
        ),
      ),
    );
  }
}
