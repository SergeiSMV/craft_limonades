import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Длина бейджа: сервер режет 16 цифр на `login` (первые 8) и `secret` (последние 8).
const int badgeLength = 16;

/// Экран ожидания скана бейджа: крупная подсказка + автофокусное поле.
///
/// Поле нужно и в intent-режиме сканера: на нём держится ручной ввод бейджа (эмулятор, отладка)
/// и клавиатурный режим сканера, если устройство настроено по-старому.
class BadgeScanView extends StatelessWidget {
  const BadgeScanView({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onTap,
    required this.softKeyboard,
    required this.onSwitchMode,
  });

  /// Контроллер поля ввода бейджа.
  final TextEditingController controller;

  /// Фокус поля — держим его на поле, чтобы ловить клавиатурный ввод сканера.
  final FocusNode focusNode;

  /// Обработчик изменения значения поля.
  final ValueChanged<String> onChanged;

  /// Обработчик отправки значения поля.
  final ValueChanged<String> onSubmitted;

  /// Тап по полю — включить экранную клавиатуру для ручного ввода.
  final VoidCallback onTap;

  /// Экранная клавиатура запрошена. Пока `false`, IME не открывается вовсе
  /// (`TextInputType.none`) — сканер шлёт ввод в сфокусированное поле и без неё,
  /// а мелькание клавиатуры на ТСД дёргает высоту окна.
  final bool softKeyboard;

  /// Переключение на вход по логину и паролю.
  final VoidCallback onSwitchMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.kSidebarBg,
        image: DecorationImage(
          image: Assets.images.tsdLoginBg.provider(),
          fit: BoxFit.cover,
          opacity: 0.3,
        ),
      ),
      // Прокрутка с `minHeight` во всю высоту: содержимое стоит по центру, пока место есть, и
      // прокручивается, когда его нет. Без этого экран рвался в ландшафте — там высота 360 dp
      // против нужных ~485, и колонка переполнялась на 128 px «зеброй». Тот же приём, что у
      // формы логина: обе формы входа ведут себя одинаково при повороте и при клавиатуре.
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: AppInsets.all24,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: AppSizes.kIcon256,
                      child: Image(
                        image: Assets.images.employeeBadge.provider(),
                      ),
                    ),
                    AppBoxes.kHeight24,
                    Text(
                      t.loginScreen.scanPrompt,
                      textAlign: TextAlign.center,
                      style: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kTileText,
                      ),
                    ),
                    AppBoxes.kHeight8,
                    Container(
                      height: AppSizes.kIcon60,
                      decoration: BoxDecoration(
                        borderRadius: AppBorders.kPill,
                        image: DecorationImage(
                          image: Assets.images.fakeBarcode.provider(),
                          colorFilter: ColorFilter.mode(
                            AppColors.kTileText,
                            BlendMode.srcIn,
                          ),
                          fit: BoxFit.cover,
                          opacity: 0.2,
                        ),
                      ),
                      child: TextField(
                        cursorHeight: 25,
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        showCursor: true,
                        cursorColor: Colors.white,
                        keyboardType: softKeyboard
                            ? TextInputType.number
                            : TextInputType.none,
                        onTap: onTap,
                        textAlign: TextAlign.center,
                        style: SemiboldTextStyles().semiboldInter18.copyWith(
                          color: AppColors.kTileText,
                        ),
                        // Пускаем только цифры и не больше 16 — сканер/ручной ввод дают чистый бейдж.
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(badgeLength),
                        ],
                        decoration: const InputDecoration(
                          focusColor: Colors.white,
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.transparent),
                          ),
                        ),
                        onChanged: onChanged,
                        onSubmitted: onSubmitted,
                      ),
                    ),
                    AppBoxes.kHeight24,
                    TextButton(
                      onPressed: onSwitchMode,
                      child: Text(
                        t.loginScreen.usePassword,
                        style: RegularTextStyles().regularInter14.copyWith(
                          color: AppColors.kTileText,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.kTileText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
