import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/strings.g.dart';

/// Экран входа. В P0-05 — временное поле ручного ввода бейджа (доказывает путь до бэкенда);
/// в P0-06 поле заменится сканом бейджа (сканер ТСД / камера).
@RoutePage()
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Контроллер для ввода бейджа.
  final _badgeController = TextEditingController();

  @override
  void dispose() {
    _badgeController.dispose();
    super.dispose();
  }

  /// Реакция на смену состояния входа: при неудаче показываем ошибку.
  void onAuthState(BuildContext context, AuthState state) {
    if (state is AuthUnauthenticated && state.failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.loginScreen.errorSnackbar)));
    }
  }

  /// Отправка введённого бейджа на вход.
  void submit(BuildContext context) {
    context.read<AuthCubit>().login(_badgeController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.loginScreen.title)),
      body: BlocConsumer<AuthCubit, AuthState>(
        listener: onAuthState,
        builder: (context, state) {
          final loading = state is AuthAuthenticating;
          return Padding(
            padding: AppInsets.all24,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // TODO(P0-06): заменить на скан бейджа (сканер ТСД / камера).
                TextField(
                  controller: _badgeController,
                  keyboardType: TextInputType.number,
                  maxLength: 16,
                  decoration: InputDecoration(
                    labelText: t.loginScreen.badgeLabel,
                  ),
                ),
                AppBoxes.kHeight24,
                ElevatedButton(
                  onPressed: loading ? null : () => submit(context),
                  child: loading
                      ? const SizedBox(
                          height: AppSizes.kIcon24,
                          width: AppSizes.kIcon24,
                          child: CircularProgressIndicator(
                            strokeWidth: AppSizes.kIcon2,
                          ),
                        )
                      : Text(t.loginScreen.loginButton),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
