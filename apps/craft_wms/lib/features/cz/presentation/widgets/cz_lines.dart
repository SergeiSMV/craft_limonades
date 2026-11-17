import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/detail_card.dart';

/// Строки карточек «Честного знака» (CZ-04) - те же приёмы, что в карточке проблемы склада:
/// белая плашка, жирный заголовок, каждый факт своей подписанной строкой, мета мелко и серо.

/// Плашка со строками.
Widget czCard(List<Widget> lines) => DetailCard(
  padding: AppInsets.all12,
  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
);

/// Заголовок плашки.
Widget czStrong(String text) => Text(
  text,
  style: SemiboldTextStyles().semiboldInter16.copyWith(
    color: AppColors.kSidebarHover,
  ),
);

/// Факт строкой.
Widget czText(String text) => Text(
  text,
  style: RegularTextStyles().regularInter14.copyWith(
    color: AppColors.kTextMain,
  ),
);

/// Мета: когда, код - мелко и серо.
Widget czMuted(String text) => Padding(
  padding: AppInsets.top4,
  child: Text(
    text,
    style: RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    ),
  ),
);
