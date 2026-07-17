import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/router/app_router.dart';

/// Главное меню — заглушка. Экраны операций (приёмка, размещение, справочники)
/// подключаются в фазах P1–P6. Здесь пока профиль + выход + доступ к логам.
@RoutePage()
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Переход к экрану логирования.
  void goToLogs(BuildContext context) {
    context.router.push(const DebugLogRoute());
  }

  /// Выход из приложения.
  void logout(BuildContext context) {
    context.read<AuthCubit>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthCubit>().state;
    final profile = state is AuthAuthenticated ? state.profile : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.homeScreen.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: t.homeScreen.logsTooltip,
            onPressed: () => goToLogs(context),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: t.homeScreen.logoutTooltip,
            onPressed: () => logout(context),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (profile != null) ...[
              Text(
                t.homeScreen.loggedInAs(name: profile.fullName),
                style: const TextStyle(fontSize: AppSizes.kText22),
              ),
              AppBoxes.kHeight8,
              Text(
                t.homeScreen.loginRole(
                  login: profile.login,
                  role: profile.role,
                ),
              ),
            ],
            AppBoxes.kHeight24,
            Text(t.homeScreen.operationsPlaceholder),
          ],
        ),
      ),
    );
  }
}
