import 'package:flutter/material.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/config/app_mode_switch.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';

/// Ссылка «Демо-режим» под формой входа (ADHOC-67).
///
/// Что: переводит ТСД на демо-сервер с выдуманным складом — показ системы и проверка
///      модератором RuStore без учётной записи рабочего склада.
/// Как: приложение перезапускается в демо-режиме ([AppModeSwitch.enterDemo]) и открывает
///      экран входа демо, где вход — одной кнопкой. Подтверждения здесь нет: им служит
///      сам экран демо с кнопкой «Вернуться к рабочему серверу».
///      В сборке без адреса демо-сервера ссылки нет.
class DemoModeLink extends StatelessWidget {
  const DemoModeLink({super.key});

  /// Перейти в демо-режим (перезапуск приложения).
  Future<void> enterDemo() => AppModeSwitch.enterDemo();

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.demoAvailable) return const SizedBox.shrink();
    return TextButton(
      onPressed: enterDemo,
      child: Text(
        t.loginScreen.demoLink,
        style: RegularTextStyles().regularInter14.copyWith(
          color: AppColors.kTileText,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.kTileText,
        ),
      ),
    );
  }
}
