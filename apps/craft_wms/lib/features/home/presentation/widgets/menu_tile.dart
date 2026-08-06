import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/theme/bold_text.dart';
import '../../../../core/theme/regular_text.dart';

/// Плитка главного меню ТСД: крупная цветная кнопка с иконкой, заголовком и подписью.
/// [enabled] = false — раздел-заглушка (визуально приглушён, тап показывает уведомление).
class MenuTile extends StatelessWidget {
  const MenuTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.imageIcon,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  /// заголовок
  final String title;

  /// подпись
  final String subtitle;

  /// цвет
  final Color color;

  /// callback при нажатии
  final VoidCallback onTap;

  /// enabled = false — раздел-заглушка (визуально приглушён, тап показывает уведомление).
  final bool enabled;

  /// PNG-иконка из ассетов (FlutterGen); если null — рисуем [icon].
  final AssetGenImage imageIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: AppBorders.kCircular12,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppBorders.kCircular12,
        child: Padding(
          padding: AppInsets.h8 + AppInsets.top4,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              imageIcon.image(height: AppSizes.kIcon85),
              AppBoxes.kHeight8,
              Text(
                title,
                textAlign: TextAlign.center,
                style: BoldTextStyles().boldInter16.copyWith(
                  color: AppColors.kTileText,
                ),
              ),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RegularTextStyles().regularInter11.copyWith(
                  height: 1.1,
                  color: AppColors.kTileText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
