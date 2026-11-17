import 'package:flutter/material.dart';

import '../../../../core/config/app_mode_switch.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/bold_text.dart';
import '../../../../core/theme/regular_text.dart';
import 'privacy_policy_link.dart';

/// Экран входа в демо-режиме (ADHOC-67).
///
/// Что: объяснение, что это демо, вход одной кнопкой и возврат к рабочему серверу.
/// Зачем: на демо-сервере нет учётных записей для показа - вход идёт под демо-пользователем
///        с полными правами; сканер для входа не нужен (модератор RuStore проверяет на телефоне).
/// Оформление - как у остальных форм входа: тот же фон, логотип, стили текста и кнопок.
class DemoLoginView extends StatelessWidget {
  const DemoLoginView({super.key, required this.onSignIn});

  /// Вход под демо-пользователем.
  final VoidCallback onSignIn;

  /// Вернуться к рабочему серверу (перезапуск приложения).
  Future<void> leaveDemo() => AppModeSwitch.leaveDemo();

  @override
  Widget build(BuildContext context) {
    final linkStyle = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTileText,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.kTileText,
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.kSidebarBg,
        image: DecorationImage(
          image: Assets.images.tsdLoginBg.provider(),
          fit: BoxFit.cover,
          opacity: 0.3,
        ),
      ),
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
                      height: AppSizes.kIcon140,
                      child: Image(image: Assets.images.logoAlpha.provider()),
                    ),
                    AppBoxes.kHeight24,
                    Text(
                      t.loginScreen.demoTitle,
                      textAlign: TextAlign.center,
                      style: BoldTextStyles().boldInter20.copyWith(
                        color: AppColors.kTileText,
                      ),
                    ),
                    AppBoxes.kHeight16,
                    Text(
                      t.loginScreen.demoBody,
                      textAlign: TextAlign.center,
                      style: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kTileText,
                      ),
                    ),
                    AppBoxes.kHeight24,
                    SizedBox(
                      width: double.infinity,
                      height: AppSizes.kIcon50,
                      child: FilledButton(
                        onPressed: onSignIn,
                        child: Text(t.loginScreen.demoSignIn),
                      ),
                    ),
                    AppBoxes.kHeight16,
                    TextButton(
                      onPressed: leaveDemo,
                      child: Text(t.loginScreen.demoLeave, style: linkStyle),
                    ),
                    const PrivacyPolicyLink(),
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
