import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/auth/auth_cubit.dart';
import 'core/di/injection.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// Корневой виджет. Держит роутер и слушает состояние входа, чтобы гейтить навигацию.
class CraftWmsApp extends StatelessWidget {
  CraftWmsApp({super.key});

  final AppRouter _router = getIt<AppRouter>();

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: getIt<AuthCubit>(),
      // Навигация по состоянию аутентификации — единое место правды:
      // вошли → главное меню, вышли/протух refresh → экран входа.
      child: BlocListener<AuthCubit, AuthState>(
        listener: (context, state) {
          switch (state) {
            case AuthAuthenticated():
              _router.replaceAll([const HomeRoute()]);
            case AuthUnauthenticated():
              _router.replaceAll([const LoginRoute()]);
            case AuthUnknown():
            case AuthAuthenticating():
              break;
          }
        },
        child: MaterialApp.router(
          title: 'Craft WMS',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          routerConfig: _router.config(),
        ),
      ),
    );
  }
}
