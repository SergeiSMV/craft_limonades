import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart'; // Key — для аргументов маршрутов в app_router.gr.dart
import 'package:injectable/injectable.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/debug/presentation/debug_log_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../../features/stock/data/catalog_models.dart'; // Good — аргумент StockDetailRoute
import '../../features/stock/presentation/goods_list_screen.dart';
import '../../features/stock/presentation/stock_detail_screen.dart';
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
        // Стартовый маршрут — заставка: пока проверяется сессия, не мелькает экран входа.
        AutoRoute(page: SplashRoute.page, initial: true),
        AutoRoute(page: LoginRoute.page),
        AutoRoute(page: HomeRoute.page, guards: [_authGuard]),
        // Справочники/остатки — под авторизацией (кормят экраны ТСД).
        AutoRoute(page: GoodsListRoute.page, guards: [_authGuard]),
        AutoRoute(page: StockDetailRoute.page, guards: [_authGuard]),
        AutoRoute(page: DebugLogRoute.page),
      ];
}
