import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/strings.g.dart';

/// Экран входа — ожидание скана бейджа.
///
/// Что: автофокусное поле ловит ввод сканера ТСД (16 цифр + Enter как HID-клавиатура)
///      и одновременно годится для ручного ввода на эмуляторе.
/// Зачем: вход — это один скан бейджа, без формы и лишних нажатий.
/// Как: при наборе 16 цифр или по Enter отправляем бейдж на вход; ошибки — крупно.
/// Полноценная интеграция сканера — P2-01 (сейчас заглушка, см. P0-07).
@RoutePage()
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Длина бейджа (сервер режет на login 8 + secret 8).
  static const _badgeLength = 16;

  /// Контроллер поля ввода бейджа.
  final _badgeController = TextEditingController();

  /// Фокус поля — держим его на поле, чтобы ловить ввод сканера.
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _badgeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Реакция на смену состояния входа: при неудаче — крупная понятная ошибка,
  /// поле очищаем и возвращаем фокус для следующего скана.
  void onAuthState(BuildContext context, AuthState state) {
    if (state is AuthUnauthenticated && state.failure != null) {
      _badgeController.clear();
      _focusNode.requestFocus();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_messageFor(state.failure!))));
    }
  }

  /// Текст ошибки под её тип (что показать кладовщику).
  String _messageFor(Failure failure) => switch (failure) {
    AuthFailure() => t.loginScreen.errorAuth,
    NetworkFailure() => t.loginScreen.errorNetwork,
    _ => t.loginScreen.errorUnknown,
  };

  /// Автосабмит при наборе полного бейджа (сканер вводит 16 цифр разом).
  void onBadgeChanged(String value) {
    if (value.length == _badgeLength) {
      submit(context);
    }
  }

  /// Отправка бейджа на вход, если введено ровно 16 цифр; иначе — подсказка.
  void submit(BuildContext context) {
    final badge = _badgeController.text.trim();
    if (badge.length != _badgeLength) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.loginScreen.errorInvalid)));
      return;
    }
    context.read<AuthCubit>().login(badge);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.loginScreen.title)),
      body: BlocConsumer<AuthCubit, AuthState>(
        listener: onAuthState,
        builder: (context, state) {
          // Пока идёт вход — крупный индикатор без поля (проверку сессии при старте
          // держит splash-экран, сюда состояние unknown уже не приходит).
          if (state is AuthAuthenticating) {
            return _LoadingView(message: t.loginScreen.loggingIn);
          }
          return _ScanView(
            controller: _badgeController,
            focusNode: _focusNode,
            onChanged: onBadgeChanged,
            onSubmitted: (_) => submit(context),
          );
        },
      ),
    );
  }
}

/// Индикатор загрузки с подписью (проверка сессии / вход).
class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          AppBoxes.kHeight24,
          Text(message, style: const TextStyle(fontSize: AppSizes.kText20)),
        ],
      ),
    );
  }
}

/// Экран ожидания скана: крупная подсказка + автофокусное поле бейджа.
class _ScanView extends StatelessWidget {
  const _ScanView({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
  });

  /// Контроллер поля ввода бейджа.
  final TextEditingController controller;

  /// Фокус поля — держим его на поле, чтобы ловить ввод сканера.
  final FocusNode focusNode;

  /// Обработчик изменения значения поля.
  final ValueChanged<String> onChanged;

  /// Обработчик отправки значения поля.
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppInsets.all24,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.qr_code_scanner, size: AppSizes.kIcon96),
          AppBoxes.kHeight24,
          Text(
            t.loginScreen.scanPrompt,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: AppSizes.kText24),
          ),
          AppBoxes.kHeight24,
          TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: AppSizes.kText22),
            // Пускаем только цифры и не больше 16 — сканер/ручной ввод дают чистый бейдж.
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(_LoginScreenState._badgeLength),
            ],
            decoration: InputDecoration(labelText: t.loginScreen.badgeLabel),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ],
      ),
    );
  }
}
