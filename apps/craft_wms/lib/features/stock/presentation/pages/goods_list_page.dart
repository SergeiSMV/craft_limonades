import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/appbar_image.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../bloc/goods_list_cubit.dart';
import '../widgets/active_chips.dart';
import '../widgets/goods_result.dart';
import '../widgets/stock_filter_button.dart';

/// Экран «Остатки»: список товаров с поиском и фильтрами (группа/поставщик).
/// Фильтры вынесены в нижний лист (кнопка с бейджем), активные — чипами под поиском;
/// применяются сразу при выборе. Тап по товару → карточка его остатков.
@RoutePage()
class GoodsListPage extends StatelessWidget {
  const GoodsListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<GoodsListCubit>()..init(),
      child: const _GoodsListView(),
    );
  }
}

/// Виджет экрана «Остатки» с поиском, фильтрами и списком товаров.
class _GoodsListView extends StatefulWidget {
  const _GoodsListView();

  @override
  State<_GoodsListView> createState() => _GoodsListViewState();
}

class _GoodsListViewState extends State<_GoodsListView> {
  /// Дебаунс поиска: не дёргаем API на каждый символ, а ждём 350 мс после последнего ввода.
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

  /// Открыть раздел «Ввод остатков» (проход склада, P-FastStart).
  void openStockEntry(BuildContext context) =>
      context.router.push(const StockEntryRoute());

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        body: Column(
          children: [
            Stack(
              children: [
                AppbarImage(image: Assets.images.featuredSnacks),
                Padding(
                  padding: AppInsets.h8 + AppInsets.top32,
                  child: Column(
                    children: [
                      Padding(
                        padding: AppInsets.right8,
                        child: Row(
                          children: [
                            PageHeader(
                              title: t.stockListScreen.title,
                              goBack: goBack,
                            ),
                            const Spacer(),
                            InkWell(
                              onTap: () => openStockEntry(context),
                              child: Icon(
                                MdiIcons.playlistPlus,
                                size: AppSizes.kIcon30,
                                color: AppColors.kNeumorphicBg,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AppBoxes.kHeight16,
                      // Строка поиска + компактная кнопка фильтров (с бейджем активных).
                      Row(
                        children: [
                          Expanded(child: searchField()),
                          AppBoxes.kWidth8,
                          const FilterButton(),
                        ],
                      ),
                      const ActiveChips(),
                    ],
                  ),
                ),
              ],
            ),
            const Expanded(child: GoodsResult()),
          ],
        ),
      ),
    );
  }

  /// Поиск с неоморфным стилем: светлая плашка с тенью, иконка поиска слева.
  Neumorphic searchField() {
    return Neumorphic(
      style: NeumorphicStyle(
        shadowLightColor: AppColors.kNeumorphicLight,
        shadowDarkColor: AppColors.kNeumorphicDark,
        intensity: 1,
        color: AppColors.kNeumorphicBg,
        depth: -2,
        shape: NeumorphicShape.flat,
      ),
      child: TextField(
        cursorColor: AppColors.kTextMain,
        cursorWidth: 1.5,
        cursorHeight: 20,
        onChanged: onSearchChanged,
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: AppInsets.right2 + AppInsets.left12,
            child: Icon(
              Icons.search,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 0,
            minHeight: 0,
          ),
          hintText: t.stockListScreen.searchHint,
          hintStyle: RegularTextStyles().regularInter16.copyWith(
            color: AppColors.kBorderDashed,
          ),
          border: const OutlineInputBorder(
            borderRadius: AppBorders.kCircular8,
            borderSide: BorderSide.none,
          ),
          isDense: true,
        ),
      ),
    );
  }
}
