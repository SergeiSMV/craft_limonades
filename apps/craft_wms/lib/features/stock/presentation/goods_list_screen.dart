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
/// Фильтры вынесены в нижний лист (кнопка с бейджем), активные — чипами под поиском;
/// применяются сразу при выборе. Тап по товару → карточка его остатков.
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
                  // Строка поиска + компактная кнопка фильтров (с бейджем активных).
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          cursorColor: AppColors.kTextMain,
                          cursorWidth: 1.5,
                          cursorHeight: 20,
                          onChanged: onSearchChanged,
                          decoration: InputDecoration(
                            focusedBorder: const OutlineInputBorder(
                              borderRadius: AppBorders.kCircular8,
                              borderSide: BorderSide(
                                color: AppColors.kTextMain,
                              ),
                            ),
                            prefixIcon: Padding(
                              padding: AppInsets.right2 + AppInsets.left12,
                              child: Icon(
                                Icons.search,
                                size: AppSizes.kIcon20,
                                color: AppColors.kTextMain,
                              ),
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 0,
                              minHeight: 0,
                            ),
                            hintText: t.stockListScreen.searchHint,
                            hintStyle: RegularTextStyles().regularInter16
                                .copyWith(color: AppColors.kBorderDashed),
                            border: const OutlineInputBorder(
                              borderRadius: AppBorders.kCircular8,
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      AppBoxes.kWidth8,
                      const _FilterButton(),
                    ],
                  ),
                  const _ActiveChips(),
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

/// Кнопка открытия листа фильтров с бейджем числа активных фильтров.
class _FilterButton extends StatelessWidget {
  const _FilterButton();

  /// Открыть нижний лист фильтров. Cubit пробрасываем через .value — лист им управляет.
  void openFilters(BuildContext context) {
    final cubit = context.read<GoodsListCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _FilterSheet()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    // Склад пока не учитываем (ADR-0016) — только группа + поставщик.
    final count =
        (state.groupId != null ? 1 : 0) + (state.supplierId != null ? 1 : 0);

    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: AppBorders.kCircular8,
          border: Border.all(color: AppColors.kBorder),
        ),
        child: IconButton(
          icon: const Icon(Icons.tune),
          tooltip: t.stockListScreen.filterTooltip,
          onPressed: () => openFilters(context),
        ),
      ),
    );
  }
}

/// Активные фильтры чипами (группа/поставщик). «✕» снимает фильтр сразу.
class _ActiveChips extends StatelessWidget {
  const _ActiveChips();

  /// Имя по id из справочника (пусто, если не нашли).
  String _nameOf(Iterable<String> names) => names.isEmpty ? '' : names.first;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    final chips = <Widget>[];
    if (state.groupId != null) {
      final name = _nameOf(
        state.groups.where((g) => g.id == state.groupId).map((g) => g.name),
      );
      chips.add(_chip(name, () => cubit.setGroup(null)));
    }
    if (state.supplierId != null) {
      final name = _nameOf(
        state.suppliers
            .where((s) => s.id == state.supplierId)
            .map((s) => s.name),
      );
      chips.add(_chip(name, () => cubit.setSupplier(null)));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: AppInsets.top8,
      // child: SingleChildScrollView(
      //   scrollDirection: Axis.horizontal,
      //   child: Row(children: chips),
      // ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Wrap(spacing: 4, runSpacing: 8, children: chips),
        ),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onDeleted) => Chip(
    elevation: 2,
    shadowColor: AppColors.kStockItemBorder,
    side: BorderSide(color: AppColors.kStockItemBg),
    shape: RoundedRectangleBorder(borderRadius: AppBorders.kPill),
    backgroundColor: AppColors.kStockItemBg,
    label: Text(label, style: RegularTextStyles().regularInter12),
    onDeleted: onDeleted,
    deleteIcon: const Icon(Icons.close, size: AppSizes.kIcon16),
  );
}

/// Нижний лист фильтров: группа + поставщик (применяются сразу) + «Сбросить».
class _FilterSheet extends StatelessWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GoodsListCubit>().state;
    final cubit = context.read<GoodsListCubit>();

    return SafeArea(
      child: Padding(
        padding: AppInsets.all16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.stockListScreen.filtersTitle,
              style: SemiboldTextStyles().semiboldInter18,
            ),
            AppBoxes.kHeight16,
            // key по значению — чтобы после «Сбросить» дропдаун показал «Все».
            DropdownButtonFormField<String?>(
              key: ValueKey('flt-group-${state.groupId}'),
              initialValue: state.groupId,
              isExpanded: true,
              borderRadius: AppBorders.kCircular8,
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
            AppBoxes.kHeight12,
            DropdownButtonFormField<String?>(
              key: ValueKey('flt-supplier-${state.supplierId}'),
              initialValue: state.supplierId,
              isExpanded: true,
              borderRadius: AppBorders.kCircular8,
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
            AppBoxes.kHeight16,
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: cubit.resetFilters,
                    child: Text(t.stockListScreen.reset),
                  ),
                ),
                AppBoxes.kWidth12,
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t.stockListScreen.done),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
          padding: AppInsets.h16 + AppInsets.v8,
          child: Text(
            t.stockListScreen.found(total: state.total),
            style: RegularTextStyles().regularInter14.copyWith(
              color: AppColors.kTextMuted,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            physics: const BouncingScrollPhysics(),
            itemCount: state.goods.length,
            itemBuilder: (context, i) {
              final good = state.goods[i];
              return Padding(
                padding: AppInsets.bottom4 + AppInsets.h8,
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
