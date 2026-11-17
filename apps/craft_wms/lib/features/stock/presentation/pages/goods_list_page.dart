import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/auth/session_rights.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/search_field.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../contents/presentation/bloc/boxes_cubit.dart';
import '../../../contents/presentation/contents_navigation.dart';
import '../../../contents/presentation/widgets/boxes/boxes_list.dart';
import '../bloc/goods_list_cubit.dart';
import '../bloc/stock_goods_cubit.dart';
import '../goods_search_handlers.dart';
import '../widgets/goods_list/goods_result.dart';
import '../widgets/goods_list/stock_header.dart';

/// Экран «Остатки»: вкладки «Товары» и «Короба» (P5-05-1).
///
/// «Товары» - товары, которые есть на складе, с количеством (ADHOC-33): из снимка склада, без
/// связи тоже. Поиск и фильтры (группа/поставщик/склады) - в нижнем листе (кнопка с бейджем),
/// активные - чипами под поиском; применяются сразу при выборе. Тап по товару → карточка его
/// остатков. «Короба» - короба склада и поиск по короткому коду с ярлыка. Весь справочник
/// товаров - «Номенклатура» из меню главного экрана.
@RoutePage()
class GoodsListPage extends StatelessWidget {
  const GoodsListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<GoodsListCubit>(
          create: (_) => getIt<StockGoodsCubit>()..init(),
        ),
        BlocProvider(create: (_) => getIt<BoxesCubit>()),
      ],
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
    with HardwareScanListener, GoodsSearchHandlers {
  /// Строка поиска коробов по короткому коду (вкладка «Короба», P5-05-1). Своя, а не общая
  /// с товарами: переключение вкладки не должно терять набранное в другой.
  final _boxController = TextEditingController();

  /// Открытая вкладка: 0 - «Товары», 1 - «Короба».
  int _tab = 0;

  /// Переключить вкладку; короба грузятся при первом заходе.
  void selectTab(int index) {
    dismissKeyboard();
    setState(() => _tab = index);
    if (index == 1) context.read<BoxesCubit>().open();
  }

  /// Ввод в строке коробов завершён: скан QR или ячейки открывает их, остальное - код с ярлыка.
  Future<void> onBoxSubmitted(String value) async {
    final input = value.trim();
    if (input.isEmpty || !deduper.allow(input)) return;
    final boxes = context.read<BoxesCubit>();
    if (await openScannedContents(context, ScanCode(raw: input))) {
      _boxController.clear();
      await boxes.submitQuery('');
      return;
    }
    await boxes.submitQuery(input);
  }

  /// Очистить строку коробов - снова весь список.
  void clearBoxSearch() {
    _boxController.clear();
    context.read<BoxesCubit>().submitQuery('');
  }

  /// Код с аппаратного сканера (intent-режим). На «Товарах» ведём тем же путём, что и
  /// завершённый ввод в строке поиска - ШК открывает карточку, прочее ищется подстрокой.
  @override
  void onHardwareScan(ScanCode code) =>
      _tab == 1 ? onBoxScan(code) : onSearchSubmitted(code.raw);

  /// Скан на вкладке «Короба»: QR короба и этикетка ячейки открывают их, прочее - не короб.
  Future<void> onBoxScan(ScanCode code) async {
    if (!deduper.allow(code.raw)) return;
    if (await openScannedContents(context, code)) return;
    if (mounted) snack(t.contents.notCellOrBox);
  }

  /// Назад на предыдущий экран (главное меню). Отложенный поиск гасим: экран уходит,
  /// а его запрос иначе улетел бы вдогонку.
  void goBack() {
    context.read<GoodsListCubit>().cancelPendingSearch();
    context.router.maybePop();
  }

  /// Открыть раздел «Ввод остатков» (проход склада, P-FastStart). Клавиатуру гасим по той же
  /// причине, что и при переходе в карточку товара, - чтобы не всплывала на возврате.
  void openStockEntry(BuildContext context) {
    context.read<GoodsListCubit>().cancelPendingSearch();
    dismissKeyboard();
    context.router.push(const StockEntryRoute());
  }

  @override
  void dispose() {
    _boxController.dispose();
    super.dispose();
  }

  /// Строка поиска «Коробов» по короткому коду с ярлыка.
  Widget _boxesSearch() => SearchField(
    hintText: t.contents.boxSearchHint,
    controller: _boxController,
    onChanged: context.read<BoxesCubit>().setQueryDebounced,
    onSubmitted: onBoxSubmitted,
    onClear: clearBoxSearch,
  );

  @override
  Widget build(BuildContext context) {
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        body: Column(
          children: [
            StockHeader(
              title: t.stockListScreen.title,
              goBack: goBack,
              // «Ввод остатков» - по праву должности (ADHOC-51).
              openStockEntry:
                  sessionCan(context, Rights.tsdStockEntry, withoutSession: true)
                  ? () => openStockEntry(context)
                  : null,
              search: _tab == 0 ? goodsSearch() : _boxesSearch(),
            ),
            Padding(
              padding: AppInsets.h8 + AppInsets.top8,
              child: TabSwitch(
                labels: [t.contents.tabGoods, t.contents.tabBoxes],
                selected: _tab,
                onSelected: selectTab,
                activeColor: AppColors.kTileStock,
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [GoodsResult(), BoxesList()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
