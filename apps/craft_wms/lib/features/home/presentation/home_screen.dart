import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/auth/auth_cubit.dart';
import '../../../core/config/app_config.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/gen/assets.gen.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/bold_text.dart';
import '../../../core/theme/regular_text.dart';
import '../../../core/widgets/system_ui_wrapper.dart';
import 'widgets/menu_tile.dart';

/// Главное меню ТСД (P1-07): шапка (сотрудник · склад) + сетка плиток операций.
/// Рабочая плитка — «Остатки»; остальные — заглушки (тап показывает уведомление).
@RoutePage()
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Переход к экрану логирования.
  void goToLogs(BuildContext context) =>
      context.router.push(const DebugLogRoute());

  /// Выход из приложения.
  void logout(BuildContext context) => context.read<AuthCubit>().logout();

  /// Открыть рабочий раздел «Остатки» (список товаров).
  void openStock(BuildContext context) =>
      context.router.push(const GoodsListRoute());

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
                        imageIcon: Assets.icons.menuIcons.colorInboxIcon,
                        color: AppColors.kTileReceipt,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.movementTitle,
                        subtitle: t.homeScreen.tiles.movementSubtitle,
                        imageIcon: Assets.icons.menuIcons.colorSwapboxIcon,
                        color: AppColors.kTileMovement,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.tasksTitle,
                        subtitle: t.homeScreen.tiles.tasksSubtitle,
                        imageIcon: Assets.icons.menuIcons.colorTasksIcon,
                        color: AppColors.kTileTasks,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.findTitle,
                        subtitle: t.homeScreen.tiles.findSubtitle,
                        imageIcon: Assets.icons.menuIcons.colorSearchIcon,
                        color: AppColors.kTileFind,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.historyTitle,
                        subtitle: t.homeScreen.tiles.historySubtitle,
                        imageIcon: Assets.icons.menuIcons.colorHistoryIcon,
                        color: AppColors.kTileHistory,
                        enabled: false,
                        onTap: () => showStub(context),
                      ),
                      MenuTile(
                        title: t.homeScreen.tiles.stockTitle,
                        subtitle: t.homeScreen.tiles.stockSubtitle,
                        imageIcon: Assets.icons.menuIcons.colorStockIcon,
                        color: AppColors.kTileStock,
                        onTap: () => openStock(context),
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
