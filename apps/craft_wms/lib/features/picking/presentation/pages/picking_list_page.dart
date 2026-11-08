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
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/picking_list_cubit.dart';
import '../widgets/picking_orders_list.dart';

/// «СБОРКА» (P9-06): несобранные заказы любой даты - свои, свободные, у других. Касание -
/// заказ. Без связи - свои заказы, открытые на терминале.
@RoutePage()
class PickingListPage extends StatelessWidget {
  const PickingListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<PickingListCubit>()..load(),
      child: const _ListView(),
    );
  }
}

class _ListView extends StatelessWidget {
  const _ListView();

  /// Открыть заказ; по возврату список обновляется - заказ могли взять или отпустить.
  Future<void> open(BuildContext context, String id, int number) async {
    final cubit = context.read<PickingListCubit>();
    await context.router.push(PickingOrderRoute(orderId: id, number: number));
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
          child: BlocBuilder<PickingListCubit, PickingListState>(
            builder: (context, state) => PickingOrdersList(
              state: state,
              onRetry: context.read<PickingListCubit>().load,
              onOpen: (id, number) => open(context, id, number),
            ),
          ),
        ),
      ),
    );
  }
}
