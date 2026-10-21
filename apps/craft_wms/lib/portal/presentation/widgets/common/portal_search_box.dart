import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле поиска над списком портала — вдавленное, как поле поиска на ТСД (ADHOC-26; общее
/// с «Проблемами склада» — P6-07-3).
class PortalSearchBox extends StatelessWidget {
  const PortalSearchBox({
    super.key,
    required this.hint,
    required this.onChanged,
  });

  final String hint;
  final ValueChanged<String> onChanged;

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
        onChanged: onChanged,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTextMain,
        ),
        cursorColor: AppColors.kTextMain,
        decoration: InputDecoration(
          isDense: true,
          // Без рамок и заливки темы портала: поле — сама вдавленная плашка, янтарная рамка
          // в фокусе и белый фон темы сделали бы его обычным полем поверх неё.
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: AppInsets.searchBox,
          prefixIcon: const Icon(
            Icons.search,
            size: AppSizes.kIcon20,
            color: AppColors.kTextMuted,
          ),
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kSidebarMuted,
          ),
        ),
      ),
    );
  }
}
