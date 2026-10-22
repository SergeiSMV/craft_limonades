import 'package:flutter/material.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../theme/regular_text.dart';

/// Плашка над сеансом, вернувшимся из отказа сервера (ADHOC-41, долг 26).
///
/// Зачем: кладовщик правит сеанс, который сервер отклонил, и должен видеть, какие строки не
/// прошли: сервер называет их товаром, партией и местами (ADHOC-40). Плашка держится, пока
/// сеанс не завершён снова. Общая для перемещения и размещения — текст даёт экран.
class RejectedSessionBanner extends StatelessWidget {
  const RejectedSessionBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.kDanger,
      borderRadius: AppBorders.kCircular8,
      child: Padding(
        padding: AppInsets.all12,
        child: Text(
          text,
          style: RegularTextStyles().regularInter14.copyWith(
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
