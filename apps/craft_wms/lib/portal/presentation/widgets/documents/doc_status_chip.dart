import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/semibold_text.dart';

/// Статус документа в 1С: «Ожидает» — янтарный, «Проведено» — зелёный.
class DocStatusChip extends StatelessWidget {
  const DocStatusChip({super.key, required this.posted});

  final bool posted;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon, label) = posted
        ? (
            AppColors.kBadgeSuccessBg,
            AppColors.kBadgeSuccessText,
            Icons.check,
            t.portal.documents.statusPosted,
          )
        : (
            AppColors.kBadgeWarningBg,
            AppColors.kBadgeWarningText,
            Icons.hourglass_empty,
            t.portal.documents.statusWaiting,
          );
    return Container(
      padding: AppInsets.badge,
      decoration: BoxDecoration(color: bg, borderRadius: AppBorders.kPill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppSizes.kIcon16, color: fg),
          AppBoxes.kWidth4,
          // Гибко, с многоточием: бейдж не вылезает из колонки ни при каком шрифте и масштабе.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SemiboldTextStyles().semiboldInter12.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}
