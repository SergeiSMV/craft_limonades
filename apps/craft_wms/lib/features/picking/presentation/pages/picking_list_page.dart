import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/picking_list_cubit.dart';
import '../bloc/picking_shipped_cubit.dart';
import '../widgets/picking_orders_list.dart';
import '../widgets/picking_shipped_view.dart';

/// «СБОРКА» (P9-06): несобранные заказы любой даты - свои, свободные, у других. Касание -
/// заказ. Без связи - свои заказы, открытые на терминале.
@RoutePage()
class PickingListPage extends StatelessWidget {
  const PickingListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<PickingListCubit>()..load()),
        BlocProvider(create: (_) => getIt<PickingShippedCubit>()),
      ],
      child: const _ListView(),
    );
  }
}

class _ListView extends StatefulWidget {
  const _ListView();

  @override
  State<_ListView> createState() => _ListViewState();
}

class _ListViewState extends State<_ListView> {
  /// 0 - текущие, 1 - завершённые (отгруженные за дату).
  int _tab = 0;

  void selectTab(int index) {
    setState(() => _tab = index);
    final shipped = context.read<PickingShippedCubit>();
    if (index == 1 && shipped.state.status != PickingShippedStatus.loaded) {
      shipped.load();
    }
  }

  /// Отгруженный заказ: его короба, отгрузка уже отмечена.
  Future<void> openShipped(String id, int number) =>
      context.router.push(PickingShipmentRoute(orderId: id, number: number));

  /// Открыть заказ; по возврату список обновляется - заказ могли взять или отпустить.
  Future<void> open(BuildContext context, String id, int number) async {
    final cubit = context.read<PickingListCubit>();
    await context.router.push(PickingOrderRoute(orderId: id, number: number));
    await cubit.load();
  }

  /// Открыть собранный заказ: ярлыки и отгрузка; по возврату - список заново.
  Future<void> openPicked(BuildContext context, String id, int number) async {
    final cubit = context.read<PickingListCubit>();
    await context.router.push(
      PickingShipmentRoute(orderId: id, number: number),
    );
    await cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: AppSizes.kIcon60,
          flexibleSpace: ClipRRect(
            borderRadius: AppBorders.kBottom10,
            child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
          ),
          title: PageHeader(
            title: t.picking.title,
            goBack: () => context.router.maybePop(),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: AppInsets.h8 + AppInsets.v16,
                child: TabSwitch(
                  labels: [t.picking.tabCurrent, t.picking.tabShipped],
                  selected: _tab,
                  onSelected: selectTab,
                  activeColor: AppColors.kTilePicking,
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    BlocBuilder<PickingListCubit, PickingListState>(
                      builder: (context, state) => PickingOrdersList(
                        state: state,
                        onRetry: context.read<PickingListCubit>().load,
                        onOpen: (id, number) => open(context, id, number),
                        onOpenPicked: (id, number) =>
                            openPicked(context, id, number),
                      ),
                    ),
                    PickingShippedView(onOpen: openShipped),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
