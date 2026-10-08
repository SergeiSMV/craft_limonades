import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/theme/regular_text.dart';

/// Сообщение на месте списка: «ячейка пуста», «короб не найден», «нет связи».
class ContentsMessage extends StatelessWidget {
  const ContentsMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.all24,
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kTextMuted,
          ),
        ),
      ),
    );
  }
}
