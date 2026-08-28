import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../splash/presentation/pages/splash_page.dart';

/// Экран входа — ожидание скана бейджа.
///
/// Что: автофокусное поле ловит ввод сканера ТСД (16 цифр + Enter как HID-клавиатура)
///      и одновременно годится для ручного ввода на эмуляторе.
/// Зачем: вход — это один скан бейджа, без формы и лишних нажатий.
/// Как: при наборе 16 цифр или по Enter отправляем бейдж на вход; ошибки — крупно.
/// Полноценная интеграция сканера — P2-01 (сейчас заглушка, см. P0-07).
@RoutePage()
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
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
              return const SplashPage();
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
        color: AppColors.kSidebarBg,
        image: DecorationImage(
          image: Assets.images.tsdLoginBg.provider(),
          fit: BoxFit.cover,
          opacity: 0.3,
        ),
      ),
      child: Padding(
        padding: AppInsets.all24,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: AppSizes.kIcon256,
              child: Image(image: Assets.images.employeeBadge.provider()),
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
                keyboardType: TextInputType.number,
                onTap: onTap,
                textAlign: TextAlign.center,
                style: SemiboldTextStyles().semiboldInter18.copyWith(
                  color: AppColors.kTileText,
                ),
                // Пускаем только цифры и не больше 16 — сканер/ручной ввод дают чистый бейдж.
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(
                    _LoginPageState._badgeLength,
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
