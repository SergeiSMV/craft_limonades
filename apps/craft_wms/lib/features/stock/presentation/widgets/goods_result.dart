import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/regular_text.dart';
import '../../data/catalog_models.dart';
import '../bloc/goods_list_cubit.dart';
import 'error_retry.dart';

/// Виджет результат: список товаров / индикатор / ошибка / пусто.
class GoodsResult extends StatelessWidget {
  const GoodsResult({super.key});

  /// Открыть карточку остатков выбранного товара.
  void openDetail(BuildContext context, Good good) {
    context.router.push(StockDetailRoute(good: good));
  }

  /// Повторить загрузку товаров (например, после ошибки). Вызывается из колбэка (тап), поэтому
  /// только `read` — `watch` допустим лишь внутри build.
  void retryLoad(BuildContext context) {
    final cubit = context.read<GoodsListCubit>();
    cubit.setQuery(cubit.state.query);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;

    if (state.status == GoodsListStatus.loading && state.goods.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == GoodsListStatus.error) {
      return ErrorRetry(onRetry: () => retryLoad(context));
    }
    if (state.goods.isEmpty) {
      return Center(child: Text(t.stockListScreen.empty));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: AppInsets.h16 + AppInsets.v8,
          child: Text(
            t.stockListScreen.found(total: state.total),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            // Ближе 400px к концу — тянем следующую страницу (loadMore защищён от повторов).
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
                context.read<GoodsListCubit>().loadMore();
              }
              return false;
            },
            child: ListView.builder(
              padding: EdgeInsets.zero,
              physics: const BouncingScrollPhysics(),
              // +1 на футер-индикатор, пока есть непогруженные товары.
              itemCount: state.goods.length + (state.hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= state.goods.length) {
                  return const Padding(
                    padding: AppInsets.v16,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final good = state.goods[i];
                return Padding(
                  padding: AppInsets.all8,
                  child: NeumorphicButton(
                    onPressed: () => openDetail(context, good),
                    style: NeumorphicStyle(
                      shadowLightColor: AppColors.kNeumorphicLight,
                      shadowDarkColor: AppColors.kNeumorphicDark,
                      intensity: 1,
                      color: AppColors.kNeumorphicBg,
                      depth: 3,
                      shape: NeumorphicShape.flat,
                      boxShape: NeumorphicBoxShape.roundRect(
                        BorderRadius.circular(8),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          good.name,
                          style: RegularTextStyles().regularInter14.copyWith(
                            height: 1.2,
                            color: AppColors.kTextMain,
                          ),
                        ),
                        Text(
                          [
                            if (good.code != null) good.code!,
                            if (good.groupName != null) good.groupName!,
                          ].join(' · '),
                          style: RegularTextStyles().regularInter10.copyWith(
                            color: AppColors.kTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
