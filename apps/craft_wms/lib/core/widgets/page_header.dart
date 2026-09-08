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
    this.trailing,
  });

  /// Заголовок страницы.
  final String title;

  final Color? textColor;

  /// Функция обратного вызова при нажатии на заголовок для возврата на предыдущую страницу.
  final VoidCallback? goBack;

  /// Действие справа в шапке — редкое и не рисковое нажатие (меню, отбрасывание).
  /// Вне [InkWell] возврата: иначе тап по нему уводил бы со страницы.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Без действия — ровно прежний виджет. `Expanded` здесь появляться не должен: шапка
    // встречается и там, где ширина не ограничена (внутри Row без констрейнтов), и гибкий
    // ребёнок в таком месте роняет вёрстку.
    if (trailing == null) return _titleButton();
    // Действие стоит ВНЕ InkWell возврата: внутри него тап по действию сначала уводил бы
    // со страницы. Заголовок остаётся кнопкой «назад» во всю оставшуюся ширину.
    return Row(
      children: [
        Expanded(child: _titleButton()),
        trailing!,
      ],
    );
  }

  /// Заголовок со стрелкой — он же кнопка возврата.
  Widget _titleButton() {
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
