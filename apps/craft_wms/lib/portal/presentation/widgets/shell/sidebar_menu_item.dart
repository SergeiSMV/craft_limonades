import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Заголовок секции меню (мелкий, приглушённый, капсом).
class SidebarSectionTitle extends StatelessWidget {
  const SidebarSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.sectionTitle,
      child: Text(
        title.toUpperCase(),
        style: SemiboldTextStyles().semiboldInter12.copyWith(
          color: AppColors.kTextMuted,
          letterSpacing: AppSizes.kSectionLetterSpacing,
        ),
      ),
    );
  }
}

/// Пункт меню: иконка + подпись. Выбранный — вдавленная неоморфная плашка, тот же приём, что
/// у поля поиска на ТСД: «нажатый» пункт утоплен в фон, остальные лежат на нём ровно.
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
    final content = Padding(
      padding: AppInsets.menuItem,
      child: Row(
        children: [
          Icon(
            icon,
            color: active ? AppColors.kPrimary : AppColors.kTextMuted,
            size: AppSizes.kIcon20,
          ),
          AppBoxes.kWidth16,
          Text(
            label.toLowerCase(),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMain,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: AppInsets.menuItemOuter,
      child: active
          ? Neumorphic(
              style: NeumorphicStyle(
                // Чуть темнее фона сайдбара — цвет поля поиска на ТСД: утопленный пункт
                // читается выбранным не только по тени.
                color: AppColors.kNeumorphicBg,
                shadowLightColor: AppColors.kNeumorphicLight,
                shadowDarkColor: AppColors.kNeumorphicDark,
                intensity: 1,
                depth: AppSizes.kNeumorphicInsetDepth,
                shape: NeumorphicShape.flat,
                // Скругление как у кнопок портала (ADHOC-25), а не пилюля.
                boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
              ),
              child: content,
            )
          : Material(
              color: Colors.transparent,
              shape: const RoundedRectangleBorder(
                borderRadius: AppBorders.kCircular12,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                hoverColor: AppColors.kBorder,
                child: content,
              ),
            ),
    );
  }
}
