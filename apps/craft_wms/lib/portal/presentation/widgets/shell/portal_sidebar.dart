import 'package:flutter/material.dart';

import '../../../../core/auth/profile.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import 'nav_item.dart';
import 'sidebar_menu_item.dart';

/// Боковая панель портала (ADHOC-56, навигация Shopify Polaris): логотип, меню по секциям,
/// пользователь внизу. Плоская: свой чуть более тёмный фон, без теней и плашек.
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
      menuChildren.add(AppBoxes.kHeight8);
    }

    return Container(
      width: AppSizes.kSidebarWidth,
      color: AppColors.kNavBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Рукописный логотип (белый на прозрачном) перекрашен в приглушённый цвет текста:
          // srcIn кладёт цвет только на непрозрачные пиксели надписи.
          Padding(
            padding: AppInsets.all24,
            child: Assets.images.logoAlpha.image(
              color: AppColors.kTextMuted,
              colorBlendMode: BlendMode.srcIn,
              fit: BoxFit.contain,
              semanticLabel: t.portal.brand,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: AppInsets.navList,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: menuChildren,
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppColors.kBorder),
          Padding(
            padding: AppInsets.all16,
            child: Row(
              children: [
                CircleAvatar(
                  radius: AppSizes.kIcon16,
                  backgroundColor: AppColors.kSecondary,
                  child: Text(
                    _initials,
                    style: SemiboldTextStyles().semiboldInter12.copyWith(
                      color: Colors.white,
                    ),
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
                        style: SemiboldTextStyles().semiboldInter13.copyWith(
                          color: AppColors.kTextMain,
                        ),
                      ),
                      Text(
                        // Должность (ADHOC-49); у сервера без должностей — роль.
                        profile.position.isEmpty
                            ? profile.role
                            : profile.position,
                        overflow: TextOverflow.ellipsis,
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
        ],
      ),
    );
  }
}
