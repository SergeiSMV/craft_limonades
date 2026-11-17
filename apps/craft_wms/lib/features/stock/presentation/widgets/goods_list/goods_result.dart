import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../../core/constants/app_boxes.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/theme/regular_text.dart';
import '../../../../../core/theme/semibold_text.dart';
import '../../../../../core/utils/keyboard.dart';
import '../../../../../core/utils/qty_format.dart';
import '../../../../../core/widgets/error_retry.dart';
import '../../../../contents/presentation/widgets/common/freshness_note.dart';
import '../../../../contents/presentation/widgets/common/pending_mark.dart';
import '../../../data/catalog_models.dart';
import '../../bloc/goods_list_cubit.dart';

/// Виджет результат: список товаров / индикатор / ошибка / пусто.
///
/// В «Остатках» (ADHOC-33) у строки - количество на выбранных складах и пометка «ожидает
/// отправки», над списком - подпись, на когда снимок; «потянуть вниз» обновляет снимок.
class GoodsResult extends StatelessWidget {
  const GoodsResult({super.key});

  /// Открыть карточку остатков выбранного товара. Перед уходом гасим клавиатуру, иначе
  /// на возврате Flutter восстановит фокус поиска и она всплывёт сама.
  ///
  /// И гасим отложенный поиск: экран списка при `push` не уничтожается, поэтому таймер,
  /// заведённый последней набранной буквой, доработал бы уже из-под карточки. При просадке
  /// связи его ошибка подменила бы список, и кладовщик вернулся бы на экран ошибки,
  /// хотя поиск не трогал.
  ///
  /// По возврату список обновляется ([GoodsListCubit.returnedFromCard]): карточка обновила
  /// снимок и могла поправить товар, и строка не должна расходиться с увиденным в карточке.
  void openDetail(BuildContext context, Good good) {
    final cubit = context.read<GoodsListCubit>()..cancelPendingSearch();
    dismissKeyboard();
    context.router
        .push(StockDetailRoute(good: good))
        .then((_) => cubit.returnedFromCard(good.id));
  }

  /// Повторить загрузку товаров (после ошибки или «потянуть вниз»). Вызывается из колбэка,
  /// поэтому только `read` - `watch` допустим лишь внутри build.
  Future<void> retryLoad(BuildContext context) =>
      context.read<GoodsListCubit>().refresh();

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
      return RefreshIndicator(
        onRefresh: () => retryLoad(context),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: AppInsets.h8 + AppInsets.v8,
          children: [
            if (state.freshness case final f?) FreshnessNote(freshness: f),
            Center(child: Text(t.stockListScreen.empty)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: AppInsets.h16 + AppInsets.v8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.freshness case final f?) FreshnessNote(freshness: f),
              Text(
                t.stockListScreen.found(total: state.total),
                style: RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kTextMuted,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            // Ближе 400px к концу - тянем следующую страницу (loadMore защищён от повторов).
            onNotification: (n) {
              if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
                context.read<GoodsListCubit>().loadMore();
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => retryLoad(context),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
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
                  final qty = state.stockQty[good.id];
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
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  good.name.isEmpty
                                      ? t.contents.unknownGood
                                      : good.name,
                                  style: RegularTextStyles().regularInter14
                                      .copyWith(
                                        height: 1.2,
                                        color: AppColors.kTextMain,
                                      ),
                                ),
                                Text(
                                  [
                                    if (good.code != null) good.code!,
                                    if (good.groupName != null) good.groupName!,
                                  ].join(' · '),
                                  style: RegularTextStyles().regularInter10
                                      .copyWith(color: AppColors.kTextMuted),
                                ),
                                if (state.pendingGoods.contains(good.id))
                                  const PendingMark(),
                              ],
                            ),
                          ),
                          if (qty != null) ...[
                            AppBoxes.kWidth12,
                            Text(
                              fmtQty(qty),
                              style: SemiboldTextStyles().semiboldInter16
                                  .copyWith(color: AppColors.kTextMain),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
