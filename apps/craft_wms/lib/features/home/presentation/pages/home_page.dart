import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/auth/auth_cubit.dart';
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
import '../../../../core/theme/bold_text.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../widgets/menu_tile.dart';

/// Главное меню ТСД (P1-07): шапка (сотрудник · склад) + сетка плиток операций.
/// Рабочая плитка — «Остатки»; остальные — заглушки (тап показывает уведомление).
@RoutePage()
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  /// Переход к экрану логирования.
  void goToLogs(BuildContext context) =>
      context.router.push(const DebugLogRoute());

  /// Переход к диагностике сканера (служебный экран наладки).
  void goToScannerProbe(BuildContext context) =>
      context.router.push(const ScannerProbeRoute());

  /// Обновить справочники вручную: перечитать их с сервера в локальный кэш.
  ///
  /// Нужно, когда на портале только что загрузили номенклатуру или напечатали новые ячейки, —
  /// ждать следующего входа в приложение ради этого незачем.
  Future<void> refreshCatalogs(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t.homeScreen.syncStarted)));
    final res = await getIt<CatalogSyncService>().refresh();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            res.isRight ? t.homeScreen.syncDone : t.homeScreen.syncFailed,
          ),
        ),
      );
  }

  /// Выход из приложения.
  void logout(BuildContext context) => context.read<AuthCubit>().logout();

  /// Открыть рабочий раздел «Остатки» (список товаров).
  void openStock(BuildContext context) =>
      context.router.push(const GoodsListRoute());

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
                          onTap: () => goToScannerProbe(context),
                          child: Text(
                            t.homeScreen.scannerTooltip,
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
                      MenuTile(
                        title: t.homeScreen.tiles.receiptTitle,
                        subtitle: t.homeScreen.tiles.receiptSubtitle,
                        imageIcon: Assets.icons.menuIcons.arrival,
                        color: AppColors.kTileReceipt,
                        enabled: false,
                        onTap: () => showStub(context),
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
                      MenuTile(
                        title: t.homeScreen.tiles.stockTitle,
                        subtitle: t.homeScreen.tiles.stockSubtitle,
                        imageIcon: Assets.icons.menuIcons.inbox,
                        color: AppColors.kTileStock,
                        onTap: () => openStock(context),
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
