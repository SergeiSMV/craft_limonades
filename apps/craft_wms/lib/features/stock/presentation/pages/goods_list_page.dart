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
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/barcode.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/appbar_image.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../data/catalog_models.dart';
import '../bloc/goods_list_cubit.dart';
import '../widgets/goods_list/active_chips.dart';
import '../widgets/goods_list/goods_result.dart';
import '../widgets/goods_list/stock_filter_button.dart';

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

class _GoodsListViewState extends State<_GoodsListView>
    with HardwareScanListener {
  /// Дебаунс поиска живёт в `GoodsListCubit`, а не здесь: гасить его должны и обработчики
  /// из соседних виджетов (уход в карточку товара — в `GoodsResult`), а до поля стейта
  /// они не дотягиваются.

  /// Контроллер строки поиска: по нему показываем крестик очистки (только при непустом
  /// вводе) и чистим поле по тапу.
  final _searchController = TextEditingController();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Поиск с дебаунсом: не дёргаем API на каждый символ.
  void onSearchChanged(String value) =>
      context.read<GoodsListCubit>().setQueryDebounced(value);

  /// Ввод завершён: сканер шлёт строку целиком и Enter, на софт-клавиатуре это «Поиск».
  /// Скан ШК резолвим и сразу открываем карточку товара, обычный текст — ищем подстрокой.
  ///
  /// Единая точка для обоих источников кода, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» прошла бы мимо него.
  Future<void> onSearchSubmitted(String value) async {
    final input = value.trim();
    if (input.isEmpty || !_deduper.allow(input)) return;
    final cubit = context.read<GoodsListCubit>();
    cubit
        .cancelPendingSearch(); // ввод завершён — отложенный поиск уже не нужен
    if (!looksLikeBarcode(input)) {
      await cubit.setQuery(input);
      return;
    }

    final good = await cubit.resolveBarcode(input);
    if (!mounted) return;
    if (good != null) {
      openGoodDetail(good);
      return;
    }
    // Сетевую ошибку уже показывает общий блок списка — второй раз не сообщаем.
    if (cubit.state.status == GoodsListStatus.error) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(t.stockListScreen.barcodeNotFound(barcode: input)),
        ),
      );
  }

  /// Код с аппаратного сканера (intent-режим): ведём тем же путём, что и завершённый ввод
  /// в строке поиска — ШК открывает карточку, прочее ищется подстрокой.
  @override
  void onHardwareScan(ScanCode code) => onSearchSubmitted(code.raw);

  /// Открыть карточку товара, найденного по скану. Строку поиска чистим: иначе следующий
  /// скан допишется к предыдущему коду, а список остался бы несогласован с полем.
  void openGoodDetail(Good good) {
    clearSearch();
    dismissKeyboard();
    context.router.push(StockDetailRoute(good: good));
  }

  /// Очистить строку поиска и сразу сбросить запрос. Отложенный дебаунс гасим: иначе
  /// «висящий» таймер применил бы старый текст уже после очистки.
  void clearSearch() {
    _searchController.clear();
    context.read<GoodsListCubit>().setQuery(
      '',
    ); // setQuery сам гасит отложенный поиск
  }

  /// Назад на предыдущий экран (главное меню). Отложенный поиск гасим: экран уходит,
  /// а его запрос иначе улетел бы вдогонку.
  void goBack() {
    context.read<GoodsListCubit>().cancelPendingSearch();
    context.router.maybePop();
  }

  /// Открыть раздел «Ввод остатков» (проход склада, P-FastStart). Клавиатуру гасим по той же
  /// причине, что и при переходе в карточку товара, — чтобы не всплывала на возврате.
  void openStockEntry(BuildContext context) {
    context.read<GoodsListCubit>().cancelPendingSearch();
    dismissKeyboard();
    context.router.push(const StockEntryRoute());
  }

  @override
  void dispose() {
    _searchController.dispose();
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
        controller: _searchController,
        cursorColor: AppColors.kTextMain,
        cursorWidth: 1.5,
        cursorHeight: 20,
        onChanged: onSearchChanged,
        onSubmitted: onSearchSubmitted,
        textInputAction: TextInputAction.search,
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
          // Крестик очистки — только когда в поле что-то есть. Слушаем контроллер, чтобы
          // перерисовывался один суффикс, а не весь экран на каждый символ.
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: clearSearch,
                    child: Padding(
                      padding: AppInsets.h14,
                      child: Icon(
                        Icons.close,
                        size: AppSizes.kIcon20,
                        color: AppColors.kTextMuted,
                      ),
                    ),
                  ),
          ),
          suffixIconConstraints: const BoxConstraints(
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
