import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/theme/regular_text.dart';

/// Пометка «ожидает отправки»: строку или короб изменила своя неотправленная операция.
///
/// Тем же цветом, что пометка неосновного склада в карточке товара: это не ошибка, а то, на что
/// стоит обратить внимание — сервер об этом ещё не знает.
class PendingMark extends StatelessWidget {
  const PendingMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppInsets.top4,
      padding: AppInsets.badge,
      decoration: BoxDecoration(
        color: AppColors.kBadgeWarningBg,
        borderRadius: BorderRadius.circular(AppSizes.kText12),
      ),
      child: Text(
        t.contents.pending,
        style: RegularTextStyles().regularInter12.copyWith(
          color: AppColors.kBadgeWarningText,
        ),
      ),
    );
  }
}
