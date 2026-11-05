import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/theme/regular_text.dart';

/// Поле ввода портала в плоском стиле (ADHOC-56): белое, рамка 1, в фокусе — синяя рамка 2.
class PortalInput extends StatelessWidget {
  const PortalInput({
    super.key,
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.obscureText = false,
    this.onSubmitted,
    this.onChanged,
    this.icon,
    this.enabled = true,
    this.textInputAction,
    this.height,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;

  /// Скрыть вводимое — поле пароля.
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;

  /// Ввод по мере набора — поиск в списке.
  final ValueChanged<String>? onChanged;

  /// Иконка слева в поле (лупа поиска); `null` — без иконки. Поле с иконкой — поиск над
  /// списком: оно в рост кнопок и фильтров панели (32), а не полей диалога.
  final IconData? icon;

  /// Поле доступно для ввода; на время входа — нет.
  final bool enabled;

  /// Действие клавиши ввода: «дальше» у логина — переход к паролю.
  final TextInputAction? textInputAction;

  /// Высота поля без иконки; `null` — по отступам. Поля экрана входа выше полей диалогов.
  final double? height;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: AppBorders.kCircular8,
      borderSide: BorderSide(color: color, width: width),
    );
    final search = icon != null;
    final style = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMain,
    );
    final fieldHeight = height;
    final field = TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      textInputAction: textInputAction,
      obscureText: obscureText,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      // Поиск растягивается на всю высоту обёртки ниже — рамка рисуется ровно в 32.
      expands: search,
      maxLines: search ? null : 1,
      style: style,
      cursorColor: AppColors.kTextMain,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.kCardBg,
        contentPadding: search
            ? AppInsets.inputSearch
            : fieldHeight == null
            ? AppInsets.input
            : AppInsets.inputTall,
        hintText: hint,
        // Длинная подсказка в узком поле — многоточием, а не второй строкой за рамкой.
        hintMaxLines: 1,
        // Заданная высота — пустым префиксом этой высоты: рамка вырастает до него при любой
        // плотности (на вебе она компактная и срезает отступы), а растянуть поле нельзя —
        // пароль однострочный. Ширина префикса — левый отступ текста.
        prefixIcon: search
            ? Icon(icon, size: AppSizes.kIcon18, color: AppColors.kTextMuted)
            : fieldHeight == null
            ? null
            : const SizedBox.shrink(),
        prefixIconConstraints: fieldHeight == null || search
            ? const BoxConstraints(minWidth: AppSizes.kControlHeight)
            : BoxConstraints.tightFor(
                width: AppInsets.input.left,
                height: fieldHeight,
              ),
        hintStyle: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kSidebarMuted,
        ),
        border: border(AppColors.kInputBorder, 1),
        enabledBorder: border(AppColors.kInputBorder, 1),
        focusedBorder: border(AppColors.kFocus, 2),
      ),
    );
    // Поиск — ровно в рост кнопок панели: высоту задаёт обёртка, а не отступы, иначе на вебе
    // (компактная плотность) рамка поля выходит тоньше кнопок.
    return search
        ? SizedBox(height: AppSizes.kControlHeight, child: field)
        : field;
  }
}
