import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';

/// Короб в списке прихода: код с ярлыка, сколько позиций, где лежит. Нажатие открывает
/// страницу короба - приёмки (ADHOC-18) или ячейки «Ввода остатков» (ADHOC-46).
///
/// Выпуклая плитка, а не строка списка: короб - вход внутрь, а не позиция, и выглядеть
/// одинаково со строками товара ему нельзя.
class BoxTile extends StatelessWidget {
  const BoxTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  /// Короб для человека: «Короб AB12 CD34», «Короб ЧЗ 1234 5678».
  final String title;

  /// Сколько позиций и где лежит.
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.bottom8,
      child: NeumorphicButton(
        onPressed: onTap,
        padding: AppInsets.all12,
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
            Icon(
              MdiIcons.packageVariantClosed,
              size: AppSizes.kIcon25,
              color: AppColors.kPrimary,
            ),
            AppBoxes.kWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: RegularTextStyles().regularInter12.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
          ],
        ),
      ),
    );
  }
}
