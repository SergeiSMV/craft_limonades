import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';

/// Стартовая заставка — показывается, пока `AuthCubit.restore()` проверяет сессию.
///
/// Что: фирменный постер «Крафтовые лимонады» на весь экран + индикатор загрузки.
/// Зачем: при холодном старте с активной сессией пользователь видит заставку и сразу
///        главное меню — без «прыжка» через экран логина (state стартует как unknown).
/// Как: навигацию дальше делает BlocListener в app.dart по состоянию AuthCubit
///      (authenticated → меню, unauthenticated → вход).
@RoutePage()
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  /// Два оборот за секунду — достаточно заметно, без «дёрганья».
  static const _spinDuration = Duration(seconds: 2);

  /// Контроллер анимации вращения.
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(vsync: this, duration: _spinDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: Assets.images.webLoginScreen.provider(),
              fit: BoxFit.cover,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: AppSizes.kIcon256,
                  child: Image(image: Assets.images.logoAlpha.provider()),
                ),
                RotationTransition(
                  turns: _spinController,
                  child: Assets.images.loading.image(
                    width: AppSizes.kIcon64,
                    height: AppSizes.kIcon64,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
