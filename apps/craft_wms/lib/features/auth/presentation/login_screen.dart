import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../../core/widgets/system_ui_wrapper.dart';

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
  void initState() {
    super.initState();
    _focusNode.addListener(_hideKeyboardOnFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_hideKeyboardOnFocus);
    _badgeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Поле получило фокус (автофокус / рефокус после ошибки) → прячем экранную
  /// клавиатуру, но фокус и курсор оставляем: HID-сканер шлёт ввод в это поле,
  /// а софт-клавиатура не нужна и лишь занимает место.
  void _hideKeyboardOnFocus() {
    if (!_focusNode.hasFocus) return;
    // Прячем ПОСЛЕ того, как фреймворк сам показал клавиатуру на получении фокуса.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNode.hasFocus) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
    });
  }

  /// Показ экранной клавиатуры по тапу по полю — для ручного ввода бейджа.
  void showKeyboard() {
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
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
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
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
              onTap: showKeyboard,
            );
          },
        ),
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: Assets.images.loginBg.provider(),
          fit: BoxFit.cover,
          opacity: 0.4,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: AppSizes.kIcon50,
              height: AppSizes.kIcon50,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: AppBorders.kCircular10,
              ),
              child: Center(
                child: SizedBox(
                  width: AppSizes.kIcon25,
                  height: AppSizes.kIcon25,
                  child: const CircularProgressIndicator(
                    color: AppColors.kGreenLime,
                    strokeWidth: AppSizes.kIcon2,
                  ),
                ),
              ),
            ),
            AppBoxes.kHeight24,
            Text(
              message,
              style: const TextStyle(
                fontSize: AppSizes.kText16,
                color: Colors.white,
              ),
            ),
          ],
        ),
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
    required this.onTap,
  });

  /// Контроллер поля ввода бейджа.
  final TextEditingController controller;

  /// Фокус поля — держим его на поле, чтобы ловить ввод сканера.
  final FocusNode focusNode;

  /// Обработчик изменения значения поля.
  final ValueChanged<String> onChanged;

  /// Обработчик отправки значения поля.
  final ValueChanged<String> onSubmitted;

  /// Тап по полю — показать экранную клавиатуру для ручного ввода.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        image: DecorationImage(
          image: Assets.images.loginBg.provider(),
          fit: BoxFit.cover,
          opacity: 0.4,
        ),
      ),
      child: Padding(
        padding: AppInsets.all24,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // const Icon(Icons.qr_code_scanner, size: AppSizes.kIcon96),
            SizedBox(
              width: AppSizes.kIcon180,
              child: Image(image: Assets.images.scanBadge.provider()),
            ),
            // AppBoxes.kHeight24,
            Text(
              t.loginScreen.scanPrompt,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: AppSizes.kText16,
                color: Colors.white,
              ),
            ),
            AppBoxes.kHeight24,
            Container(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: Assets.images.fakeBarcode.provider(),
                  colorFilter: ColorFilter.mode(Colors.white, BlendMode.srcIn),
                  fit: BoxFit.cover,
                  opacity: 0.3,
                ),
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                showCursor: true,
                cursorColor: Colors.white,
                keyboardType: TextInputType.number,
                onTap: onTap,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: AppSizes.kText24,
                  color: Colors.white,
                ),
                // Пускаем только цифры и не больше 16 — сканер/ручной ввод дают чистый бейдж.
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(
                    _LoginScreenState._badgeLength,
                  ),
                ],
                decoration: InputDecoration(
                  // labelText: t.loginScreen.badgeLabel,
                  // labelStyle: const TextStyle(color: Colors.white),
                  focusColor: Colors.white,
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.transparent),
                  ),
                ),
                onChanged: onChanged,
                onSubmitted: onSubmitted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
