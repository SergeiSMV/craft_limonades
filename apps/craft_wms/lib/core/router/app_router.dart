import 'package:auto_route/auto_route.dart';
import 'package:injectable/injectable.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/debug/presentation/debug_log_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import 'guards.dart';

part 'app_router.gr.dart';

/// Карта навигации приложения (auto_route). Классы роутов (LoginRoute и т.д.)
/// и `.page` генерируются в app_router.gr.dart командой build_runner.
@AutoRouterConfig()
@lazySingleton
class AppRouter extends RootStackRouter {
  AppRouter(this._authGuard);

  final AuthGuard _authGuard;

  @override
  List<AutoRoute> get routes => [
        AutoRoute(page: LoginRoute.page, initial: true),
        AutoRoute(page: HomeRoute.page, guards: [_authGuard]),
        AutoRoute(page: DebugLogRoute.page),
      ];
}
