import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart'; // Key — для аргументов маршрутов в app_router.gr.dart
import 'package:injectable/injectable.dart';

import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/debug/presentation/pages/debug_log_page.dart';
import '../../features/debug/presentation/pages/printer_probe_page.dart';
import '../../features/debug/presentation/pages/scanner_probe_page.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/splash/presentation/pages/splash_page.dart';
import '../../features/stock/data/catalog_models.dart'; // Good — аргумент StockDetailRoute
import '../../features/stock/presentation/pages/goods_list_page.dart';
import '../../features/stock/presentation/pages/stock_detail_page.dart';
import '../../features/stock_entry/presentation/pages/stock_entry_page.dart';
import '../../features/sync/presentation/pages/sync_queue_page.dart';
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
    // Ввод стартовых остатков (P-FastStart) — под авторизацией (кладовщик).
    AutoRoute(page: StockEntryRoute.page, guards: [_authGuard]),
    AutoRoute(page: DebugLogRoute.page),
    // Диагностика сканера — служебный экран наладки (P2-01).
    AutoRoute(page: ScannerProbeRoute.page),
    AutoRoute(page: PrinterProbeRoute.page),
    // Несинхронизированные операции: разбор отклонённых сервером (P2-06).
    AutoRoute(page: SyncQueueRoute.page, guards: [_authGuard]),
  ];
}
