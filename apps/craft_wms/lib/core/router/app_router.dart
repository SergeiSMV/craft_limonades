import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart'; // Key — для аргументов маршрутов в app_router.gr.dart
import 'package:injectable/injectable.dart';

import '../../features/auth/presentation/pages/login_page.dart';
import '../../features/contents/presentation/pages/cell_contents_page.dart';
import '../../features/contents/presentation/pages/load_unit_page.dart';
import '../../features/debug/presentation/pages/debug_log_page.dart';
import '../../features/debug/presentation/pages/printer_probe_page.dart';
import '../../features/debug/presentation/pages/scanner_probe_page.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/movement/presentation/pages/movement_page.dart';
import '../../features/movement/presentation/pages/movement_record_page.dart';
import '../../features/problems/presentation/pages/problem_page.dart';
import '../../features/putaway/presentation/pages/putaway_page.dart';
import '../../features/receipt/presentation/bloc/receipt_cubit.dart'; // ReceiptCubit — аргумент ReceiptBoxRoute
import '../../features/receipt/presentation/pages/receipt_box_page.dart';
import '../../features/receipt/presentation/pages/receipt_page.dart';
import '../../features/splash/presentation/pages/splash_page.dart';
import '../../features/stock/data/catalog_models.dart'; // Good — аргумент StockDetailRoute
import '../../features/stock/presentation/pages/goods_list_page.dart';
import '../../features/stock/presentation/pages/stock_detail_page.dart';
import '../../features/stock_entry/presentation/pages/stock_entry_page.dart';
import '../../features/sync/presentation/pages/sync_queue_page.dart';
import '../../features/tasks/data/tasks_models.dart'; // WarehouseTask — аргумент TaskDetailRoute
import '../../features/tasks/presentation/pages/task_detail_page.dart';
import '../../features/tasks/presentation/pages/tasks_page.dart';
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
    // Приёмка (P4-09) — под авторизацией: автор документа берётся из токена.
    AutoRoute(page: ReceiptRoute.page, guards: [_authGuard]),
    // Страница короба приёмки (ADHOC-18): тот же cubit, что у приёмки.
    AutoRoute(page: ReceiptBoxRoute.page, guards: [_authGuard]),
    // Задания для склада (P5-02-1): текущие и завершённые, карточка задания.
    AutoRoute(page: TasksRoute.page, guards: [_authGuard]),
    AutoRoute(page: TaskDetailRoute.page, guards: [_authGuard]),
    // Перемещение (P6-04): сеанс «взял → положил» с черновиком на терминале.
    AutoRoute(page: MovementRoute.page, guards: [_authGuard]),
    // Запись истории перемещений (ADHOC-28): что, откуда и куда — только онлайн.
    AutoRoute(page: MovementRecordRoute.page, guards: [_authGuard]),
    // Проблемы склада (P6-07-2): пометка брака и изолятора, без связи — очередью.
    AutoRoute(page: ProblemRoute.page, guards: [_authGuard]),
    // Выполнение задания на размещение (P5-03).
    AutoRoute(page: PutawayRoute.page, guards: [_authGuard]),
    // Содержимое ячейки и короба по скану (P5-05).
    AutoRoute(page: CellContentsRoute.page, guards: [_authGuard]),
    AutoRoute(page: LoadUnitRoute.page, guards: [_authGuard]),
    AutoRoute(page: DebugLogRoute.page),
    // Диагностика сканера — служебный экран наладки (P2-01).
    AutoRoute(page: ScannerProbeRoute.page),
    AutoRoute(page: PrinterProbeRoute.page),
    // Несинхронизированные операции: разбор отклонённых сервером (P2-06).
    AutoRoute(page: SyncQueueRoute.page, guards: [_authGuard]),
  ];
}
