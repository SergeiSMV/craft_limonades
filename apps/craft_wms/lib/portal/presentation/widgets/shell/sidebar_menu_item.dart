import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Заголовок секции меню — мелкий приглушённый текст над пунктами.
class SidebarSectionTitle extends StatelessWidget {
  const SidebarSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.navSectionTitle,
      child: Text(
        title,
        style: SemiboldTextStyles().semiboldInter12.copyWith(
          color: AppColors.kTextMuted,
        ),
      ),
    );
  }
}

/// Пункт меню (ADHOC-56, навигация Shopify Polaris): иконка и подпись, высота 36.
/// Выбранный — белая плашка и полужирная подпись, остальные подсвечиваются при наведении.
class SidebarMenuItem extends StatelessWidget {
  const SidebarMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizes.kNavItemHeight,
      child: Material(
        color: active ? AppColors.kCardBg : Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppBorders.kCircular8,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: active ? AppColors.kCardBg : AppColors.kNavHover,
          child: Padding(
            padding: AppInsets.navItem,
            child: Row(
              children: [
                Icon(
                  icon,
                  color: active ? AppColors.kTextMain : AppColors.kTextMuted,
                  size: AppSizes.kIcon18,
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (active
                                ? SemiboldTextStyles().semiboldInter13
                                : RegularTextStyles().regularInter13)
                            .copyWith(color: AppColors.kTextMain),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
