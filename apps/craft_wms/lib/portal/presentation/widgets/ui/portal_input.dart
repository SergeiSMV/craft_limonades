import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
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
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;

  /// Скрыть вводимое — поле пароля.
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: AppBorders.kCircular8,
      borderSide: BorderSide(color: color, width: width),
    );
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscureText,
      onSubmitted: onSubmitted,
      style: RegularTextStyles().regularInter14.copyWith(
        color: AppColors.kTextMain,
      ),
      cursorColor: AppColors.kTextMain,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.kCardBg,
        contentPadding: AppInsets.input,
        hintText: hint,
        hintStyle: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kSidebarMuted,
        ),
        border: border(AppColors.kInputBorder, 1),
        enabledBorder: border(AppColors.kInputBorder, 1),
        focusedBorder: border(AppColors.kFocus, 2),
      ),
    );
  }
}
