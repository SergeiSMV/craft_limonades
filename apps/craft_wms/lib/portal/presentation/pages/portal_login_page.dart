import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/constants/app_borders.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/assets.gen.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/theme/bold_text.dart';
import '../../../core/theme/regular_text.dart';
import '../widgets/ui/portal_button.dart';
import '../widgets/ui/portal_input.dart';
import '../widgets/ui/portal_modal.dart';

/// Экран входа в веб-портал по дизайн-макету: сплит-экран (тёмная бренд-панель слева,
/// белая форма справа). Узкий экран → только форма. Вход по логину/паролю (admin/оператор).
class PortalLoginPage extends StatefulWidget {
  const PortalLoginPage({super.key});

  @override
  State<PortalLoginPage> createState() => _PortalLoginPageState();
}

class _PortalLoginPageState extends State<PortalLoginPage> {
  /// контроллер логина
  final _usernameController = TextEditingController();

  /// контроллер пароля
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Отправка учётных данных на вход (пустые поля игнорируем).
  void submit() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) return;
    context.read<AuthCubit>().loginWithPassword(username, password);
  }

  /// Показ ошибки входа снекбаром (неверные данные / нет сети).
  void onAuthState(BuildContext context, AuthState state) {
    if (state is AuthUnauthenticated && state.failure != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_messageFor(state.failure!))));
    }
  }

  /// Текст ошибки под её тип.
  String _messageFor(Failure failure) => switch (failure) {
    AuthFailure() => t.portal.login.errorAuth,
    NetworkFailure() => t.portal.login.errorNetwork,
    _ => t.portal.login.errorUnknown,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.kCardBg,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          image: DecorationImage(
            image: Assets.images.webLoginScreen.provider(),
            fit: BoxFit.cover,
          ),
        ),
        child: Center(
          child: BlocConsumer<AuthCubit, AuthState>(
            listener: onAuthState,
            builder: (context, state) {
              final form = _FormPanel(
                usernameController: _usernameController,
                passwordController: _passwordController,
                loading: state is AuthAuthenticating,
                onSubmit: submit,
              );
              return SingleChildScrollView(
                child: SizedBox(
                  width: AppSizes.kFormWidth,
                  height: AppSizes.kFormHeight,
                  child: form,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Правая панель формы: заголовок, поля логин/пароль (метка сверху), кнопка входа.
class _FormPanel extends StatelessWidget {
  const _FormPanel({
    required this.usernameController,
    required this.passwordController,
    required this.loading,
    required this.onSubmit,
  });

  /// логин
  final TextEditingController usernameController;

  /// пароль
  final TextEditingController passwordController;

  /// флаг загрузки
  final bool loading;

  /// коллбэк на отправку формы
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.kCardBg,
        borderRadius: AppBorders.kCircular16,
      ),
      padding: AppInsets.all60,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Assets.images.logoAlpha.image(
            color: AppColors.kSidebarBg,
            width: AppSizes.kIcon180,
            height: AppSizes.kIcon180,
            opacity: const AlwaysStoppedAnimation(1),
          ),
          Text(
            textAlign: TextAlign.center,
            t.portal.login.title,
            style: BoldTextStyles().boldInter24.copyWith(
              color: AppColors.kSidebarHover,
            ),
          ),
          AppBoxes.kHeight8,
          Center(
            child: Text(
              textAlign: TextAlign.center,
              t.portal.login.subtitle,
              style: RegularTextStyles().regularInter14.copyWith(
                color: AppColors.kTextMuted,
              ),
            ),
          ),
          AppBoxes.kHeight32,

          /// поле ввода логина
          _LabeledField(
            label: t.portal.login.usernameLabel,
            controller: usernameController,
            enabled: !loading,
            autofocus: true,
            textInputAction: TextInputAction.next,
          ),
          AppBoxes.kHeight16,

          /// поле ввода пароля
          _LabeledField(
            label: t.portal.login.passwordLabel,
            controller: passwordController,
            enabled: !loading,
            obscure: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
          ),
          AppBoxes.kHeight24,

          /// кнопка входа — главная кнопка портала во всю ширину формы (ADHOC-56)
          PortalButton(
            label: t.portal.login.submit,
            icon: Icons.login,
            kind: PortalButtonKind.primary,
            busy: loading,
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}

/// Поле ввода с подписью сверху — поле портала в плоском стиле (ADHOC-56), как в диалогах.
class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    this.enabled = true,
    this.obscure = false,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
  });

  /// метка
  final String label;

  /// контроллер
  final TextEditingController controller;

  /// флаг активности
  final bool enabled;

  /// флаг скрытия текста
  final bool obscure;

  /// флаг автофокуса
  final bool autofocus;

  /// действие текстового поля
  final TextInputAction? textInputAction;

  /// коллбэк на отправку формы
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PortalFieldLabel(label),
      PortalInput(
        height: AppSizes.kLoginFieldHeight,
        controller: controller,
        hint: '',
        enabled: enabled,
        obscureText: obscure,
        autofocus: autofocus,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
      ),
    ],
  );
}
