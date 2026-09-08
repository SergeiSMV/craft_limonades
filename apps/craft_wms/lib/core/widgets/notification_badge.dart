import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../constants/app_sizes.dart';
import '../theme/bold_text.dart';

/// Пометка «здесь есть что-то, требующее внимания» — красный кружок с восклицательным знаком.
///
/// Что: только внешний вид. Ни данных, ни условий показа — их знает тот, кто пометку ставит.
/// Зачем отдельным виджетом: пометка нужна уже на двух входах (плитка меню и иконка в шапке),
/// и по мере появления заданий, приёмки и подбора понадобится на других плитках. Один вид
/// пометки во всём приложении — чтобы кладовщик читал её одинаково, где бы ни увидел.
class NotificationBadge extends StatelessWidget {
  const NotificationBadge({super.key, this.size = AppSizes.kIcon25});

  /// Диаметр кружка.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.kDanger,
        shape: BoxShape.circle,
        // Обводка цветом плитки не годится — плитки разноцветные. Тень отделяет кружок от
        // любого фона, на который он ляжет.
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '!',
        style: BoldTextStyles().boldInter12.copyWith(
          color: AppColors.kTileText,
        ),
      ),
    );
  }
}
