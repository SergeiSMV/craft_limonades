import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/strings.g.dart';

/// Стартовая заставка — показывается, пока `AuthCubit.restore()` проверяет сессию.
///
/// Что: нейтральный индикатор без брендинга экрана входа.
/// Зачем: при холодном старте с активной сессией пользователь видит заставку и сразу
///        главное меню — без «прыжка» через экран логина (state стартует как unknown).
/// Как: навигацию дальше делает BlocListener в app.dart по состоянию AuthCubit
///      (authenticated → меню, unauthenticated → вход).
@RoutePage()
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              t.splashScreen.title,
              style: const TextStyle(fontSize: AppSizes.kText24),
            ),
            AppBoxes.kHeight24,
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
