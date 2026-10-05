import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../bloc/receipt_models.dart';

/// Короб в общем списке приёмки: код с ярлыка, сколько позиций, где лежит. Нажатие открывает
/// страницу короба (ADHOC-18).
///
/// Выпуклая плитка, а не строка списка: короб — вход внутрь, а не позиция, и выглядеть
/// одинаково со строками товара ему нельзя.
class ReceiptBoxTile extends StatelessWidget {
  const ReceiptBoxTile({
    super.key,
    required this.box,
    required this.positions,
    required this.cellAddress,
    required this.onTap,
  });

  final ReceiptBox box;
  final int positions;
  final String cellAddress;
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
                    t.receipt.box(code: box.shortCode),
                    style: SemiboldTextStyles().semiboldInter14.copyWith(
                      color: AppColors.kSidebarHover,
                    ),
                  ),
                  Text(
                    '${t.receipt.boxPositions(count: positions)} · $cellAddress',
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
