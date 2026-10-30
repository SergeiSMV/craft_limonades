import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../ui/portal_button.dart';

/// Шапка страницы (ADHOC-56, заголовок страницы Shopify Polaris): название раздела, пояснение
/// под ним и выход справа; на узком окне слева — кнопка меню.
class PortalHeader extends StatelessWidget {
  const PortalHeader({
    super.key,
    required this.title,
    required this.onLogout,
    this.description,
    this.showMenu = false,
  });

  final String title;

  /// Пояснение к разделу под заголовком; `null` — без пояснения.
  final String? description;
  final VoidCallback onLogout;

  /// Узкое окно: меню в выдвижной панели, в шапке — кнопка, которая её открывает.
  final bool showMenu;

  /// Открыть выдвижное меню. Шапка лежит внутри каркаса, поэтому он находится по контексту.
  void openMenu(BuildContext context) => Scaffold.of(context).openDrawer();

  @override
  Widget build(BuildContext context) {
    return Container(
      // Высота растёт под пояснение: на телефоне оно в несколько строк.
      constraints: const BoxConstraints(minHeight: AppSizes.kHeaderHeight),
      padding: (showMenu ? AppInsets.h16 : AppInsets.h24) + AppInsets.v12,
      decoration: const BoxDecoration(
        color: AppColors.kBg,
        border: Border(bottom: BorderSide(color: AppColors.kBorder)),
      ),
      child: Row(
        children: [
          if (showMenu) ...[
            PortalIconButton(
              icon: Icons.menu,
              tooltip: t.portal.shell.menu,
              onPressed: () => openMenu(context),
            ),
            AppBoxes.kWidth8,
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SemiboldTextStyles().semiboldInter20.copyWith(
                    color: AppColors.kTextMain,
                  ),
                ),
                if (description != null)
                  Text(
                    description!,
                    style: RegularTextStyles().regularInter13.copyWith(
                      color: AppColors.kTextMuted,
                    ),
                  ),
              ],
            ),
          ),
          AppBoxes.kWidth16,
          PortalIconButton(
            icon: Icons.logout,
            tooltip: t.portal.shell.logout,
            onPressed: onLogout,
          ),
        ],
      ),
    );
  }
}
