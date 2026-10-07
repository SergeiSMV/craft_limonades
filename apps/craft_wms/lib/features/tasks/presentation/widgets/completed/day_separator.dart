import 'package:flutter/material.dart';

import '../../../../../core/constants/app_borders.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../common/task_format.dart';

/// Разделитель дня в ленте, как в чате: плашка с датой по центру.
class DaySeparator extends StatelessWidget {
  const DaySeparator({super.key, required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.v8,
      child: Center(
        child: Container(
          padding: AppInsets.badge,
          decoration: BoxDecoration(
            color: AppColors.kBorder,
            borderRadius: AppBorders.kPill,
          ),
          child: Text(
            dayLabel(day),
            style: SemiboldTextStyles().semiboldInter12.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
      ),
    );
  }
}
