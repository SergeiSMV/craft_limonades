import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_borders.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/assets.gen.dart';

/// Стартовая заставка — показывается, пока `AuthCubit.restore()` проверяет сессию.
///
/// Что: фирменный постер «Крафтовые лимонады» на весь экран + индикатор загрузки.
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
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: Assets.images.logo.provider(),
            fit: BoxFit.cover,
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
            ],
          ),
        ),
      ),
    );
  }
}
