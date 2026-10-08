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
///
/// [count] — число вместо восклицательного знака: «сколько ждёт» (текущие задания). Больше 99
/// показывается как «99+», чтобы кружок не распирало.
class NotificationBadge extends StatelessWidget {
  const NotificationBadge({
    super.key,
    this.size = AppSizes.kIcon25,
    this.count,
  });

  /// Диаметр кружка.
  final double size;

  /// Число в пометке; null — восклицательный знак.
  final int? count;

  /// Предел числа в кружке.
  static const _maxShown = 99;

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
        switch (count) {
          null => '!',
          final n when n > _maxShown => '$_maxShown+',
          final n => '$n',
        },
        style: BoldTextStyles().boldInter12.copyWith(
          color: AppColors.kTileText,
        ),
      ),
    );
  }
}
