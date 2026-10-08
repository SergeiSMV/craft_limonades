import 'package:flutter/material.dart';

import '../constants/app_borders.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';

/// Белая скруглённая плашка на сером фоне экрана — базовый «кирпич» карточек: остатков товара
/// (шапка, штрихкоды, места хранения) и содержимого ячейки и короба (P5-05).
///
/// Зачем отдельным виджетом: плашка повторяется во всех секциях экрана, и её оформление
/// (цвет, радиус, отступы) должно меняться в одном месте.
class DetailCard extends StatelessWidget {
  const DetailCard({
    super.key,
    required this.child,
    this.padding = AppInsets.all16,
  });

  /// Содержимое плашки.
  final Widget child;

  /// Внутренние отступы. Для списков со строками-разделителями передаётся `EdgeInsets.zero`,
  /// чтобы разделитель шёл от края плашки, а отступы задавала сама строка.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // Material, а не Container: внутри плашки бывают тапабельные зоны (раскрытие реквизитов),
    // и ripple должен рисоваться поверх белого фона и обрезаться по скруглению карточки.
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: AppColors.kCardBg,
        borderRadius: AppBorders.kCircular16,
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
