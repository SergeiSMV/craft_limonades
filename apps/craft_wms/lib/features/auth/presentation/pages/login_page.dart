import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/scanner/scanner_service.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../splash/presentation/pages/splash_page.dart';
import '../widgets/badge_scan_view.dart';
import '../widgets/demo_login_view.dart';
import '../widgets/password_login_view.dart';

/// Экран входа в двух режимах (P2-01).
///
/// Что: вход по скану бейджа (ТСД) либо по логину и паролю (устройство без сканера).
/// Зачем: бейдж физически сканируют - на смартфоне без сканера это ввод 16 цифр руками, поэтому
///        админу/оператору нужен обычный вход по учётным данным.
/// Как: режим выбирается по результату опроса устройства ([ScannerService.probe], сделан при
///      старте в `main`), а не по списку моделей - список ломается на каждой новой партии железа.
///      Выбор перекрывается вручную: на ТСД админ может войти паролем.
///
/// Бейдж принимается из двух источников сразу: поле ввода (клавиатурный режим сканера и ручной
/// набор) и поток аппаратного сканера (intent-режим). Приложение не переключает режим устройства
/// само - работает с тем, который выставлен в настройках сканера.
@RoutePage()
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with HardwareScanListener {
  /// Контроллер поля ввода бейджа.
  final _badgeController = TextEditingController();

  /// Фокус поля - держим его на поле, чтобы ловить клавиатурный ввод сканера.
  final _focusNode = FocusNode();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  /// Отсекает дубль, если устройство настроено отдавать код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Есть ли на устройстве аппаратный сканер (решает форму по умолчанию).
  late final bool _hasScanner;

  /// Показана форма логина/пароля.
  late bool _passwordMode;

  /// Нужна ли экранная клавиатура на поле бейджа. По умолчанию нет: ждём скан.
  bool _softKeyboard = false;

  @override
  void initState() {
    super.initState();
    _hasScanner = getIt<ScannerService>().lastProbe?.available ?? false;
    _passwordMode = !_hasScanner;
  }

  @override
  void dispose() {
    _badgeController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Тап по полю - бейдж набирают руками: включаем обычную клавиатуру.
  ///
  /// Прежний приём «дать фреймворку показать клавиатуру и спрятать её следующим кадром» убран:
  /// на DT50 он давал видимое мелькание снизу и череду изменений высоты окна - тот самый эффект
  /// «экран дёргается» при скане. `TextInputType.none` не даёт IME открыться вовсе.
  ///
  /// Одной смены `keyboardType` мало: соединение с IME создаётся в момент получения фокуса и
  /// живёт с той конфигурацией, с которой создано. Поэтому снимаем фокус и возвращаем его
  /// следующим кадром - связь пересоздаётся уже как обычное поле, и клавиатура открывается сама.
  void enableSoftKeyboard() {
    if (_softKeyboard) return;
    setState(() => _softKeyboard = true);
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// Смена формы входа вручную (бейдж ↔ логин/пароль).
  /// Возврат к бейджу - снова режим ожидания скана, без клавиатуры.
  void switchMode() {
    setState(() {
      _passwordMode = !_passwordMode;
      _softKeyboard = false;
    });
  }

  /// Реакция на смену состояния входа: при неудаче - понятная ошибка, поле бейджа
  /// очищаем и возвращаем фокус для следующего скана.
  void onAuthState(BuildContext context, AuthState state) {
    if (state is AuthUnauthenticated && state.failure != null) {
      if (!_passwordMode) {
        _badgeController.clear();
        _focusNode.requestFocus();
      }
      _snack(context, _messageFor(state.failure!));
    }
  }

  /// Текст ошибки под её тип и режим входа (что показать пользователю).
  String _messageFor(Failure failure) => switch (failure) {
    _ when AppConfig.isDemo => t.loginScreen.errorDemo,
    AuthFailure() =>
      _passwordMode ? t.loginScreen.errorCredentials : t.loginScreen.errorAuth,
    NetworkFailure() => t.loginScreen.errorNetwork,
    _ => t.loginScreen.errorUnknown,
  };

  /// Автосабмит при наборе полного бейджа (клавиатурный режим вводит 16 цифр разом).
  void onBadgeChanged(String value) {
    if (value.length == badgeLength) submit(context);
  }

  /// Бейдж из потока аппаратного сканера (intent-режим): код приходит мимо поля ввода.
  /// Кладём его в то же поле и идём общим путём - чтобы вход не зависел от источника кода.
  @override
  void onHardwareScan(ScanCode code) {
    if (_passwordMode || AppConfig.isDemo) return;
    _badgeController.text = code.raw.trim();
    submit(context);
  }

  /// Отправка бейджа на вход, если введено ровно 16 цифр; иначе - подсказка.
  ///
  /// Единая точка для обоих источников бейджа, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» прошла бы мимо него.
  void submit(BuildContext context) {
    final badge = _badgeController.text.trim();
    if (badge.length != badgeLength) {
      _snack(context, t.loginScreen.errorInvalid);
      return;
    }
    if (!_deduper.allow(badge)) return;
    context.read<AuthCubit>().login(badge);
  }

  /// Отправка учётных данных; пустые поля до сети не доводим.
  void submitCredentials() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      _snack(context, t.loginScreen.errorEmptyCredentials);
      return;
    }
    context.read<AuthCubit>().loginWithPassword(username, password);
  }

  /// Вход под демо-пользователем демо-сервера (ADHOC-67).
  void submitDemo() => context.read<AuthCubit>().loginDemo();

  /// Показать сообщение об ошибке входа.
  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        body: BlocConsumer<AuthCubit, AuthState>(
          listener: onAuthState,
          builder: (context, state) {
            // Пока идёт вход - крупный индикатор без формы (проверку сессии при старте
            // держит splash-экран, сюда состояние unknown уже не приходит).
            if (state is AuthAuthenticating) return const SplashPage();
            // Демо-режим (ADHOC-67): вместо бейджа и пароля - вход одной кнопкой.
            if (AppConfig.isDemo) return DemoLoginView(onSignIn: submitDemo);
            if (_passwordMode) {
              return PasswordLoginView(
                usernameController: _usernameController,
                passwordController: _passwordController,
                onSubmit: submitCredentials,
                onSwitchMode: switchMode,
                showBadgeSwitch: _hasScanner,
              );
            }
            return BadgeScanView(
              controller: _badgeController,
              focusNode: _focusNode,
              onChanged: onBadgeChanged,
              onSubmitted: (_) => submit(context),
              onTap: enableSoftKeyboard,
              softKeyboard: _softKeyboard,
              onSwitchMode: switchMode,
            );
          },
        ),
      ),
    );
  }
}
