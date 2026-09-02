import 'package:flutter/material.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';

/// Вход по логину и паролю — форма для устройства без аппаратного сканера (смартфон админа).
///
/// Зачем: бейдж физически сканируют, а на смартфоне сканера нет — вход по бейджу там возможен
/// только набором 16 цифр руками. Оформление повторяет экран скана бейджа (фон, пилюля поля,
/// те же стили текста), чтобы это читалось как один экран входа в двух режимах.
class PasswordLoginView extends StatelessWidget {
  const PasswordLoginView({
    super.key,
    required this.usernameController,
    required this.passwordController,
    required this.onSubmit,
    required this.onSwitchMode,
    required this.showBadgeSwitch,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;

  /// Отправка учётных данных.
  final VoidCallback onSubmit;

  /// Переключение на вход по скану бейджа.
  final VoidCallback onSwitchMode;

  /// Показывать ли переключатель на бейдж. На устройстве без сканера бейдж набирать негде,
  /// поэтому предлагать его там незачем.
  final bool showBadgeSwitch;

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
      child: SafeArea(
        // Прокрутка нужна, чтобы клавиатура не срезала кнопку «Войти» на низких экранах, но
        // сама по себе она сжимается по содержимому — и фон-картинка вместе с ней не доставала
        // до низа экрана. `minHeight` во всю доступную высоту возвращает фон на место и
        // одновременно оставляет форму по центру, пока прокручивать нечего.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: AppInsets.all24,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Логотип с альфой, а не иконка приложения: у `cl_icon` залитая тёмная подложка
                    // (она нарисована под сплошной фон заставки) и поверх фото читается как
                    // наклеенный прямоугольник.
                    SizedBox(
                      height: AppSizes.kIcon140,
                      child: Image(image: Assets.images.logoAlpha.provider()),
                    ),
                    AppBoxes.kHeight24,
                    Text(
                      t.loginScreen.passwordPrompt,
                      textAlign: TextAlign.center,
                      style: RegularTextStyles().regularInter14.copyWith(
                        color: AppColors.kTileText,
                      ),
                    ),
                    AppBoxes.kHeight16,
                    // Без автофокуса: клавиатура на открытии закрывала кнопку «Войти» и половину
                    // формы. Поле поднимает её по тапу — форма видна целиком с первого кадра.
                    _Field(
                      controller: usernameController,
                      hint: t.loginScreen.usernameLabel,
                    ),
                    AppBoxes.kHeight8,
                    _Field(
                      controller: passwordController,
                      hint: t.loginScreen.passwordLabel,
                      obscure: true,
                      onSubmitted: (_) => onSubmit(),
                    ),
                    AppBoxes.kHeight24,
                    SizedBox(
                      width: double.infinity,
                      height: AppSizes.kIcon50,
                      child: FilledButton(
                        onPressed: onSubmit,
                        child: Text(t.loginScreen.signIn),
                      ),
                    ),
                    if (showBadgeSwitch) ...[
                      AppBoxes.kHeight16,
                      TextButton(
                        onPressed: onSwitchMode,
                        child: Text(
                          t.loginScreen.useBadge,
                          style: RegularTextStyles().regularInter14.copyWith(
                            color: AppColors.kTileText,
                            decoration: TextDecoration.underline,
                            decorationColor: AppColors.kTileText,
                          ),
                        ),
                      ),
                    ],
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

/// Поле формы входа — та же пилюля, что у поля бейджа, но без штрихкод-подложки.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.kIcon60,
      decoration: BoxDecoration(
        borderRadius: AppBorders.kPill,
        color: AppColors.kTileText.withValues(alpha: 0.12),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: obscure ? TextInputAction.done : TextInputAction.next,
        onSubmitted: onSubmitted,
        cursorColor: Colors.white,
        textAlign: TextAlign.center,
        style: SemiboldTextStyles().semiboldInter18.copyWith(
          color: AppColors.kTileText,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: RegularTextStyles().regularInter14.copyWith(
            color: AppColors.kTileText.withValues(alpha: 0.6),
          ),
          border: const OutlineInputBorder(
            borderRadius: AppBorders.kPill,
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
