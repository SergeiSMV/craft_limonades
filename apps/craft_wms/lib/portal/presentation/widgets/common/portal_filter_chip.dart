import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Фильтр-чип в стиле пункта бокового меню: точка состояния, подпись, счётчик (ADHOC-26;
/// общий с «Проблемами склада» и выбором решения — P6-07-3).
class PortalFilterChip extends StatelessWidget {
  const PortalFilterChip({
    super.key,
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  final String label;

  /// Счётчик; `null` — без счётчика (выбор варианта, а не фильтр списка).
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  /// Цвет точки состояния; `null` — без точки («Все»).
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: AppInsets.filterChip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: AppSizes.kDotMark,
              height: AppSizes.kDotMark,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            AppBoxes.kWidth8,
          ],
          Text(
            label,
            style:
                (selected
                        ? SemiboldTextStyles().semiboldInter14
                        : RegularTextStyles().regularInter14)
                    .copyWith(color: AppColors.kTextMain),
          ),
          if (count != null) ...[
            AppBoxes.kWidth8,
            Text(
              '$count',
              style: RegularTextStyles().regularInter12.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ],
        ],
      ),
    );
    if (selected) {
      return Neumorphic(
        style: NeumorphicStyle(
          color: AppColors.kNeumorphicBg,
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          depth: AppSizes.kNeumorphicInsetDepth,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular12),
        ),
        child: content,
      );
    }
    return Material(
      color: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: AppBorders.kCircular12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.kBorder,
        child: content,
      ),
    );
  }
}
