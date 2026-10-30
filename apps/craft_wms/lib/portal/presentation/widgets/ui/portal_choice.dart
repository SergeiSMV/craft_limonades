import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Вариант выбора одного из нескольких (ADHOC-56): действие варианта решения, способ входа.
/// Выбранный — тёмная заливка, как главная кнопка; остальные — белые с рамкой.
/// Со счётчиком ([count]) — быстрый фильтр списка: «Ожидают 1С 3».
class PortalChoice extends StatelessWidget {
  const PortalChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Сколько строк под вариантом; `null` — без счётчика.
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.kButtonPrimary : AppColors.kCardBg,
      shape: RoundedRectangleBorder(
        borderRadius: AppBorders.kCircular8,
        side: BorderSide(
          color: selected ? AppColors.kButtonPrimary : AppColors.kInputBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: selected ? AppColors.kButtonPrimaryHover : AppColors.kBg,
        child: Padding(
          padding: AppInsets.choice,
          child: Text.rich(
            TextSpan(
              text: label,
              children: [
                if (count != null)
                  // Счётчик приглушён: читается подпись, число — уточнение к ней.
                  TextSpan(
                    text: '  $count',
                    style: RegularTextStyles().regularInter13.copyWith(
                      color: selected
                          ? AppColors.kBorderDashed
                          : AppColors.kTextMuted,
                    ),
                  ),
              ],
            ),
            style:
                (selected
                        ? SemiboldTextStyles().semiboldInter13
                        : RegularTextStyles().regularInter13)
                    .copyWith(
                      color: selected ? AppColors.kCardBg : AppColors.kTextMain,
                    ),
          ),
        ),
      ),
    );
  }
}
