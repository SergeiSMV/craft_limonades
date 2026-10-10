import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../common/neumorphic_icon_button.dart';

/// Верхняя панель контента: заголовок текущей вкладки + выход.
class PortalHeader extends StatelessWidget {
  const PortalHeader({
    super.key,
    required this.title,
    required this.onLogout,
    this.description,
    this.showMenu = false,
  });

  final String title;

  /// Пояснение к разделу под заголовком (ADHOC-25): в шапке, а не в теле вкладки —
  /// заголовок раздела уже здесь, и повторять его в теле незачем.
  final String? description;
  final VoidCallback onLogout;

  /// Узкий экран: меню в выдвижной панели, в шапке — кнопка, которая её открывает.
  final bool showMenu;

  /// Открыть выдвижное меню. Шапка лежит внутри каркаса, поэтому он находится по контексту.
  void openMenu(BuildContext context) => Scaffold.of(context).openDrawer();

  @override
  Widget build(BuildContext context) {
    return Container(
      // Высота — не меньше прежней, но растёт под пояснение: на телефоне оно в несколько строк.
      constraints: const BoxConstraints(minHeight: AppSizes.kHeaderHeight),
      padding: (showMenu ? AppInsets.h16 : AppInsets.h32) + AppInsets.v12,
      // Цвет — внутри decoration (нельзя одновременно color и decoration у Container).
      // Фон рабочей области, а не белый (ADHOC-25): неоморфные кнопки шапки «выдавливаются»
      // только из своего цвета, на белом их тень не читается.
      decoration: const BoxDecoration(
        color: AppColors.kBg,
        border: Border(bottom: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        children: [
          if (showMenu) ...[
            NeumorphicIconButton(
              icon: Icons.menu,
              tooltip: t.portal.shell.menu,
              onPressed: () => openMenu(context),
            ),
            AppBoxes.kWidth16,
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SemiboldTextStyles().semiboldInter20.copyWith(color: AppColors.kTextMain),
                ),
                if (description != null)
                  Text(
                    description!,
                    style: RegularTextStyles().regularInter14.copyWith(color: AppColors.kTextMuted),
                  ),
              ],
            ),
          ),
          AppBoxes.kWidth16,
          NeumorphicIconButton(
            icon: Icons.logout,
            tooltip: t.portal.shell.logout,
            onPressed: onLogout,
          ),
        ],
      ),
    );
  }
}
