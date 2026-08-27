import 'package:flutter/material.dart';

import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/theme/semibold_text.dart';

/// Заголовок секции карточки остатков («Штрихкоды (N)», «Наличие по местам хранения»):
/// тёмный текст на сером фоне, вне белой плашки.
class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title});

  /// Текст заголовка.
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.v8 + AppInsets.left6,
      child: Text(
        title,
        style: SemiboldTextStyles().semiboldInter16.copyWith(
          color: AppColors.kTextMain,
        ),
      ),
    );
  }
}
