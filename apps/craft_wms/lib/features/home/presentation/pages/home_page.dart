import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
import '../../../../core/auth/profile.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/sync/catalog_sync_service.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/theme/bold_text.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/pending_pass_badge.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../widgets/menu_tile.dart';
import '../../../receipt/data/receipt_draft_store.dart';
import '../../../sync/presentation/bloc/sync_status_cubit.dart';
import '../../../sync/presentation/widgets/sync_status_chip.dart';
import '../widgets/sync_indicator.dart';

/// Главное меню ТСД (P1-07): шапка (сотрудник · склад) + сетка плиток операций.
/// Рабочая плитка — «Остатки»; остальные — заглушки (тап показывает уведомление).
@RoutePage()
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// Переход к экрану логирования.
  void goToLogs(BuildContext context) =>
      context.router.push(const DebugLogRoute());

  /// Переход к списку несинхронизированных операций (P2-06): что не уехало и что отклонено.
  void goToSyncQueue(BuildContext context) =>
      context.router.push(const SyncQueueRoute());

  /// Переход к диагностике сканера (служебный экран наладки).
  void goToScannerProbe(BuildContext context) =>
      context.router.push(const ScannerProbeRoute());

  /// Переход к наладке принтера этикеток (служебный экран, P4-05).
  void goToPrinterProbe(BuildContext context) =>
      context.router.push(const PrinterProbeRoute());

  /// Обновить справочники вручную: перечитать их с сервера в локальный кэш.
  ///
  /// Нужно, когда на портале только что загрузили номенклатуру или напечатали новые ячейки, —
  /// ждать следующего входа в приложение ради этого незачем.
  Future<void> refreshCatalogs(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final sync = getIt<CatalogSyncService>();

    // Нажатие во время обновления (ADHOC-10). Раньше служба отвечала на него «успехом», и
    // экран рапортовал «Справочники обновлены», хотя не сделал ничего. Проверка стоит до
    // сообщения «Обновляю…», иначе кладовщик увидел бы два противоречащих друг другу текста.
    if (sync.isRunning) {
      _snack(messenger, t.homeScreen.syncAlreadyRunning);
      return;
    }

    _snack(messenger, t.homeScreen.syncStarted);
    // Заодно разгребаем очередь операций (P2-04): кладовщик, нажавший «Обновить», ждёт,
    // что всё несинхронизированное уйдёт, а не только справочники приедут.
    unawaited(getIt<SyncEngine>().drain());
    final res = await sync.refresh();
    _snack(messenger, switch (res.fold((f) => null, (outcome) => outcome)) {
      SyncOutcome.refreshed => t.homeScreen.syncDone,
      // Успели нажать дважды: первый вызов уже начал обновление, второй попал в отказ.
      SyncOutcome.alreadyRunning => t.homeScreen.syncAlreadyRunning,
      null => t.homeScreen.syncFailed,
    });
  }

  /// Показать короткое сообщение, погасив предыдущее: сообщения об обновлении идут подряд,
  /// и очередь снэкбаров показывала бы ответы на давно нажатые кнопки.
  void _snack(ScaffoldMessengerState messenger, String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Выход из приложения.
  void logout(BuildContext context) => context.read<AuthCubit>().logout();

  /// Открыть рабочий раздел «Остатки» (список товаров).
  void openStock(BuildContext context) =>
      context.router.push(const GoodsListRoute());

  /// Открыть приёмку (P4-09).
  void openReceipt(BuildContext context) =>
      context.router.push(const ReceiptRoute());

  /// Открыть раздел «Ввод остатков» (проход склада, P-FastStart).
  void openStockEntry(BuildContext context) =>
      context.router.push(const StockEntryRoute());

  /// Заглушка: раздел ещё не реализован — показываем уведомление.
  void showStub(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.homeScreen.stubSnack)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthCubit>().state;
    final profile = state is AuthAuthenticated ? state.profile : null;

    return BlocProvider(
      create: (_) => getIt<SyncStatusCubit>(),
      child: _buildScaffold(context, profile),
    );
  }

  /// Разметка меню. Вынесена из [build], чтобы провайдер состояния синхронизации стоял выше
  /// дерева, которое его читает.
  Widget _buildScaffold(BuildContext context, Profile? profile) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kSidebarBg,
        body: SafeArea(
          child: Padding(
            padding: AppInsets.h8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Шапка: слева — сотрудник (ФИО), справа — склад + меню (логи/выход).
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile?.fullName ?? '',
                            style: BoldTextStyles().boldInter16.copyWith(
                              color: AppColors.kTileText,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            AppConfig.warehouseName,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ],
                      ),
                    ),

                    SyncIndicator(running: getIt<CatalogSyncService>().running),

                    // Очередь и связь — на виду, а не только в служебном меню (P2-07).
                    SyncStatusChip(onTap: () => goToSyncQueue(context)),

                    PopupMenuButton<void>(
                      color: AppColors.kSidebarBg,
                      icon: const Icon(
                        Icons.more_vert,
                        color: AppColors.kTileText,
                      ),
                      itemBuilder: (context) => [
                        PopupMenuItem<void>(
                          onTap: () => goToLogs(context),
                          child: Text(
                            t.homeScreen.logsTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                        PopupMenuItem<void>(
                          onTap: () => refreshCatalogs(context),
                          child: Text(
                            t.homeScreen.syncTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                        PopupMenuItem<void>(
                          onTap: () => goToSyncQueue(context),
                          child: Text(
                            t.syncQueue.menuTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                        PopupMenuItem<void>(
                          onTap: () => goToScannerProbe(context),
                          child: Text(
                            t.homeScreen.scannerTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                        PopupMenuItem<void>(
                          onTap: () => goToPrinterProbe(context),
                          child: Text(
                            t.homeScreen.printerTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                        PopupMenuItem<void>(
                          onTap: () => logout(context),
                          child: Text(
                            t.homeScreen.logoutTooltip,
                            style: RegularTextStyles().regularInter14.copyWith(
                              color: AppColors.kTileText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                AppBoxes.kHeight8,
                Text(
                  t.homeScreen.title,
                  style: BoldTextStyles().boldInter20.copyWith(
                    color: AppColors.kTileText,
                  ),
                ),
                AppBoxes.kHeight8,
                // Сетка операций 2×N. Рабочая — «Остатки», прочие — заглушки.
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: AppSizes.kMenuTileSpacing,
                    crossAxisSpacing: AppSizes.kMenuTileSpacing,
                    childAspectRatio: AppSizes.kMenuTileAspect,
                    children: [
                      // Пометка незавершённой приёмки: она лежит черновиком мимо очереди,
                      // и индикатор синхронизации её не видит (тот же урок, что ADHOC-13).
                      PendingPassBuilder(
                        watch: getIt<ReceiptDraftStore>().watchHasDraft,
                        builder: (context, hasDraft) => MenuTile(
                          title: t.homeScreen.tiles.receiptTitle,
                          subtitle: t.homeScreen.tiles.receiptSubtitle,
                          imageIcon: Assets.icons.menuIcons.arrival,
                          color: AppColors.kTileReceipt,
                          showBadge: hasDraft,
                          onTap: () => openReceipt(context),
                        ),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.movementTitle,
                        subtitle: t.homeScreen.tiles.movementSubtitle,
                        imageIcon: Assets.icons.menuIcons.swapbox,
                        color: AppColors.kTileMovement,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.tasksTitle,
                        subtitle: t.homeScreen.tiles.tasksSubtitle,
                        imageIcon: Assets.icons.menuIcons.tasks,
                        color: AppColors.kTileTasks,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      // Пометка незавершённого прохода: вход в «Ввод остатков» лежит внутри
                      // «Остатков», и кладовщик должен увидеть незакрытый проход уже отсюда.
                      // Плитка рисует пометку сама — обёртка снаружи уводила кружок в зазор
                      // между плитками.
                      PendingPassBuilder(
                        builder: (context, hasPass) => MenuTile(
                          title: t.homeScreen.tiles.stockTitle,
                          subtitle: t.homeScreen.tiles.stockSubtitle,
                          imageIcon: Assets.icons.menuIcons.inbox,
                          color: AppColors.kTileStock,
                          showBadge: hasPass,
                          onTap: () => openStock(context),
                        ),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.historyTitle,
                        subtitle: t.homeScreen.tiles.historySubtitle,
                        imageIcon: Assets.icons.menuIcons.history,
                        color: AppColors.kTileHistory,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                    ],
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
