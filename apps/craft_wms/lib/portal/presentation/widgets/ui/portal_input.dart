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

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: AppBorders.kCircular8,
      borderSide: BorderSide(color: color, width: width),
    );
    final search = icon != null;
    final field = TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscureText,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      // Поиск растягивается на всю высоту обёртки ниже — рамка рисуется ровно в 32.
      expands: search,
      maxLines: search ? null : 1,
      style: RegularTextStyles().regularInter14.copyWith(
        color: AppColors.kTextMain,
      ),
      cursorColor: AppColors.kTextMain,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.kCardBg,
        contentPadding: icon == null ? AppInsets.input : AppInsets.inputSearch,
        hintText: hint,
        prefixIcon: icon == null
            ? null
            : Icon(icon, size: AppSizes.kIcon18, color: AppColors.kTextMuted),
        prefixIconConstraints: const BoxConstraints(
          minWidth: AppSizes.kControlHeight,
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
