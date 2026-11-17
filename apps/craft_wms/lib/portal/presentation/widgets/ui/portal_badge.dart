import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/theme/semibold_text.dart';

/// Смысл отметки - от него цвет: нейтральная, успех, внимание, справка, критичная.
enum PortalBadgeTone { neutral, success, warning, info, critical }

/// Отметка в строке списка (ADHOC-56, по Shopify Polaris): «Системная», «Скрыт», «По умолчанию».
/// Маленькая плашка со скруглением 6, а не пилюля, - читается спокойнее рядом с текстом строки.
class PortalBadge extends StatelessWidget {
  const PortalBadge(
    this.label, {
    super.key,
    this.tone = PortalBadgeTone.neutral,
  });

  final String label;
  final PortalBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      PortalBadgeTone.neutral => (
        AppColors.kBadgeNeutralBg,
        AppColors.kBadgeNeutralText,
      ),
      PortalBadgeTone.success => (
        AppColors.kBadgeSuccessBg,
        AppColors.kBadgeSuccessText,
      ),
      PortalBadgeTone.warning => (
        AppColors.kBadgeWarningBg,
        AppColors.kBadgeWarningText,
      ),
      PortalBadgeTone.info => (
        AppColors.kBadgeInfoBg,
        AppColors.kBadgeInfoText,
      ),
      PortalBadgeTone.critical => (
        AppColors.kBadgeCriticalBg,
        AppColors.kBadgeCriticalText,
      ),
    };
    return Container(
      padding: AppInsets.tag,
      decoration: BoxDecoration(color: bg, borderRadius: AppBorders.kCircular6),
      child: Text(
        label,
        style: SemiboldTextStyles().semiboldInter12.copyWith(color: fg),
      ),
    );
  }
}
