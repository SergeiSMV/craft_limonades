import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../theme/semibold_text.dart';

/// Виджет заголовка страницы с возможностью возврата на предыдущую страницу.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.goBack,
    this.textColor,
  });

  /// Заголовок страницы.
  final String title;

  final Color? textColor;

  /// Функция обратного вызова при нажатии на заголовок для возврата на предыдущую страницу.
  final VoidCallback? goBack;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: goBack,
      child: Row(
        children: [
          Padding(
            padding: AppInsets.right8,
            child: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: AppSizes.kIcon20,
              // color: AppColors.kSidebarHover,
              color: textColor ?? AppColors.kNeumorphicBg,
            ),
          ),
          Padding(
            padding: AppInsets.bottom4,
            child: Text(
              title,
              style: SemiboldTextStyles().semiboldInter20.copyWith(
                color: textColor ?? AppColors.kNeumorphicBg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
