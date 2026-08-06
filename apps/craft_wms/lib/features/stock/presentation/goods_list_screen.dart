import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_borders.dart';
import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_insets.dart';
import '../../../core/constants/app_sizes.dart';
import '../../../core/di/injection.dart';
import '../../../core/gen/assets.gen.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/regular_text.dart';
import '../../../core/theme/semibold_text.dart';
import '../../../core/widgets/system_ui_wrapper.dart';
import '../data/catalog_models.dart';
import 'goods_list_cubit.dart';

/// Экран «Остатки»: список товаров с поиском и фильтрами (группа/поставщик).
/// Тап по товару → карточка его остатков. Номенклатура вложена сюда (отдельного раздела нет).
@RoutePage()
class GoodsListScreen extends StatelessWidget {
  const GoodsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<GoodsListCubit>()..init(),
      child: const _GoodsListView(),
    );
  }
}

class _GoodsListView extends StatefulWidget {
  const _GoodsListView();

  @override
  State<_GoodsListView> createState() => _GoodsListViewState();
}

class _GoodsListViewState extends State<_GoodsListView> {
  Timer? _debounce;

  /// Поиск с дебаунсом: не дёргаем API на каждый символ.
  void onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      context.read<GoodsListCubit>().setQuery(value);
    });
  }

  /// Назад на предыдущий экран (главное меню).
  void goBack() => context.router.maybePop();

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.dark,
      child: Scaffold(
        body: Column(
          children: [
            Padding(
              padding: AppInsets.h8 + AppInsets.top32,
              child: Column(
                children: [
                  Padding(
                    padding: AppInsets.h8,
                    child: Row(
                      children: [
                        InkWell(
                          onTap: goBack,
                          child: Padding(
                            padding: AppInsets.right16,
                            child: Assets.icons.arrowLeft.svg(
                              height: AppSizes.kIcon20,
                            ),
                          ),
                        ),
                        Text(
                          t.stockListScreen.title,
                          style: SemiboldTextStyles().semiboldInter24,
                        ),
                      ],
                    ),
                  ),
                  AppBoxes.kHeight16,
                  TextField(
                    onChanged: onSearchChanged,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: t.stockListScreen.searchHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  AppBoxes.kHeight12,
                  const _Filters(),
                ],
              ),
            ),
            const Expanded(child: _GoodsResult()),
          ],
        ),
      ),
    );
  }
}

/// Выпадающие фильтры: группа и поставщик (из справочников, загруженных cubit'ом).
class _Filters extends StatelessWidget {
  const _Filters();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    return Column(
      children: [
        DropdownButtonFormField<String?>(
          borderRadius: BorderRadius.circular(8),
          initialValue: state.groupId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t.stockListScreen.filterGroup,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(t.stockListScreen.filterAll),
            ),
            for (final g in state.groups)
              DropdownMenuItem<String?>(
                value: g.id,
                child: Text(
                  g.name,
                  overflow: TextOverflow.ellipsis,
                  style: RegularTextStyles().regularInter14,
                ),
              ),
          ],
          onChanged: cubit.setGroup,
        ),
        AppBoxes.kHeight8,
        DropdownButtonFormField<String?>(
          borderRadius: BorderRadius.circular(8),
          initialValue: state.supplierId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: t.stockListScreen.filterSupplier,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(t.stockListScreen.filterAll),
            ),
            for (final s in state.suppliers)
              DropdownMenuItem<String?>(
                value: s.id,
                child: Text(
                  s.name,
                  overflow: TextOverflow.ellipsis,
                  style: RegularTextStyles().regularInter14,
                ),
              ),
          ],
          onChanged: cubit.setSupplier,
        ),
      ],
    );
  }
}

/// Результат: список товаров / индикатор / ошибка / пусто.
class _GoodsResult extends StatelessWidget {
  const _GoodsResult();

  /// Открыть карточку остатков выбранного товара.
  void openDetail(BuildContext context, Good good) {
    context.router.push(StockDetailRoute(good: good));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;

    if (state.status == GoodsListStatus.loading && state.goods.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == GoodsListStatus.error) {
      return _ErrorRetry(
        onRetry: () => context.read<GoodsListCubit>().setQuery(state.query),
      );
    }
    if (state.goods.isEmpty) {
      return Center(child: Text(t.stockListScreen.empty));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: AppInsets.h8,
          child: Text(
            t.stockListScreen.found(total: state.total),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            physics: BouncingScrollPhysics(),
            itemCount: state.goods.length,
            itemBuilder: (context, i) {
              final good = state.goods[i];
              return Padding(
                padding: AppInsets.v2 + AppInsets.h8,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: AppBorders.kCircular8,
                    color: AppColors.kStockItemBg,
                    border: Border(
                      bottom: BorderSide(color: AppColors.kStockItemBorder),
                    ),
                  ),
                  child: ListTile(
                    title: Text(
                      good.name,
                      style: RegularTextStyles().regularInter14.copyWith(
                        height: 1.2,
                        color: AppColors.kTextMain,
                      ),
                    ),
                    subtitle: Text(
                      [
                        if (good.code != null) good.code!,
                        if (good.groupName != null) good.groupName!,
                      ].join(' · '),
                      // maxLines: 1,
                      // overflow: TextOverflow.ellipsis,
                      style: RegularTextStyles().regularInter10.copyWith(
                        color: AppColors.kTextMuted,
                      ),
                    ),
                    onTap: () => openDetail(context, good),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Блок ошибки с кнопкой «Повторить».
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(t.stockListScreen.error),
          AppBoxes.kHeight12,
          FilledButton(
            onPressed: onRetry,
            child: Text(t.stockListScreen.retry),
          ),
        ],
      ),
    );
  }
}
