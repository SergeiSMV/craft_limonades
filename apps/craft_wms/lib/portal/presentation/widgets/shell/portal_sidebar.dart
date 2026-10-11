import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/auth/profile.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../common/neumorphic_plate.dart';
import 'nav_item.dart';
import 'sidebar_menu_item.dart';

/// Сайдбар портала: логотип, меню по секциям, карточка пользователя внизу.
class PortalSidebar extends StatelessWidget {
  const PortalSidebar({
    super.key,
    required this.sections,
    required this.selected,
    required this.onSelect,
    required this.profile,
  });

  final List<NavSection> sections;
  final int selected;
  final ValueChanged<int> onSelect;
  final Profile profile;

  /// Инициалы для аватара: первые буквы первых двух слов имени.
  String get _initials {
    final parts = profile.fullName.trim().split(RegExp(r'\s+'));
    final letters = parts.take(2).map((p) => p.isEmpty ? '' : p[0]).join();
    return letters.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Глобальный счётчик индексов пунктов (сквозной по всем секциям).
    var globalIndex = 0;
    final menuChildren = <Widget>[];
    for (final section in sections) {
      menuChildren.add(SidebarSectionTitle(section.title));
      for (final item in section.items) {
        final index = globalIndex++;
        menuChildren.add(
          SidebarMenuItem(
            icon: item.icon,
            label: item.label,
            active: index == selected,
            onTap: () => onSelect(index),
          ),
        );
      }
      menuChildren.add(AppBoxes.kHeight16);
    }

    // Светлый неоморфный сайдбар (ADHOC-25): фон рабочей области, карточка пользователя —
    // выпуклая плашка, выбранный пункт — вдавленный, как поле поиска на ТСД.
    return Container(
      width: AppSizes.kSidebarWidth,
      decoration: const BoxDecoration(
        color: AppColors.kBg,
        border: Border(right: BorderSide(color: AppColors.kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Логотип.
          // Рукописный логотип (белый на прозрачном) перекрашен в цвет иконок неоморфных
          // кнопок: srcIn кладёт цвет только на непрозрачные пиксели надписи. Лежит прямо
          // на фоне сайдбара, без плашки и разделителя.
          Padding(
            padding: AppInsets.all24,
            child: Assets.images.logoAlpha.image(
              color: AppColors.kTextMuted,
              colorBlendMode: BlendMode.srcIn,
              fit: BoxFit.contain,
              semanticLabel: t.portal.brand,
            ),
          ),
          // Меню.
          Expanded(
            child: SingleChildScrollView(
              padding: AppInsets.menuList,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: menuChildren,
              ),
            ),
          ),
          // Карточка пользователя.
          Container(
            padding: AppInsets.all24,
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.kBorder)),
            ),
            child: NeumorphicPlate(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: AppSizes.kAvatar / 2,
                    backgroundColor: AppColors.kSecondary,
                    child: Text(
                      _initials,
                      style: SemiboldTextStyles().semiboldInter16.copyWith(color: Colors.white),
                    ),
                  ),
                  AppBoxes.kWidth12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.fullName,
                          overflow: TextOverflow.ellipsis,
                          style: SemiboldTextStyles().semiboldInter14.copyWith(
                            color: AppColors.kTextMain,
                          ),
                        ),
                        Text(
                          profile.role,
                          style: RegularTextStyles().regularInter12.copyWith(
                            color: AppColors.kTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
