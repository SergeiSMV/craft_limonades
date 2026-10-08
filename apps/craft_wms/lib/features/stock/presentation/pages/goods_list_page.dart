import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/utils/barcode.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../../core/widgets/search_field.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../contents/presentation/bloc/boxes_cubit.dart';
import '../../../contents/presentation/contents_navigation.dart';
import '../../../contents/presentation/widgets/boxes/boxes_list.dart';
import '../../data/catalog_models.dart';
import '../../data/catalog_repository.dart';
import '../bloc/goods_list_cubit.dart';
import '../widgets/goods_list/active_chips.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../widgets/goods_list/goods_result.dart';
import '../widgets/goods_list/stock_header.dart';
import '../widgets/goods_list/stock_filter_button.dart';

/// Экран «Остатки»: вкладки «Товары» и «Короба» (P5-05-1).
///
/// «Товары» — список товаров с поиском и фильтрами (группа/поставщик). Фильтры вынесены в нижний
/// лист (кнопка с бейджем), активные — чипами под поиском; применяются сразу при выборе. Тап по
/// товару → карточка его остатков. «Короба» — короба склада и поиск по короткому коду с ярлыка.
@RoutePage()
class GoodsListPage extends StatelessWidget {
  const GoodsListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<GoodsListCubit>()..init()),
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
    with HardwareScanListener {
  /// Дебаунс поиска живёт в `GoodsListCubit`, а не здесь: гасить его должны и обработчики
  /// из соседних виджетов (уход в карточку товара — в `GoodsResult`), а до поля стейта
  /// они не дотягиваются.

  /// Контроллер строки поиска: по нему показываем крестик очистки (только при непустом
  /// вводе) и чистим поле по тапу.
  final _searchController = TextEditingController();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Строка поиска коробов по короткому коду (вкладка «Короба», P5-05-1). Своя, а не общая
  /// с товарами: переключение вкладки не должно терять набранное в другой.
  final _boxController = TextEditingController();

  /// Открытая вкладка: 0 — «Товары», 1 — «Короба».
  int _tab = 0;

  /// Переключить вкладку; короба грузятся при первом заходе.
  void selectTab(int index) {
    dismissKeyboard();
    setState(() => _tab = index);
    if (index == 1) context.read<BoxesCubit>().open();
  }

  /// Ввод в строке коробов завершён: скан QR или ячейки открывает их, остальное — код с ярлыка.
  Future<void> onBoxSubmitted(String value) async {
    final input = value.trim();
    if (input.isEmpty || !_deduper.allow(input)) return;
    final boxes = context.read<BoxesCubit>();
    if (await openScannedContents(context, ScanCode(raw: input))) {
      _boxController.clear();
      await boxes.submitQuery('');
      return;
    }
    await boxes.submitQuery(input);
  }

  /// Очистить строку коробов — снова весь список.
  void clearBoxSearch() {
    _boxController.clear();
    context.read<BoxesCubit>().submitQuery('');
  }

  /// Поиск с дебаунсом: не дёргаем API на каждый символ.
  void onSearchChanged(String value) =>
      context.read<GoodsListCubit>().setQueryDebounced(value);

  /// Ввод завершён: сканер шлёт строку целиком и Enter, на софт-клавиатуре это «Поиск».
  /// Скан ячейки или короба открывает их содержимое, скан ШК резолвим и сразу открываем
  /// карточку товара, обычный текст — ищем подстрокой.
  ///
  /// Единая точка для обоих источников кода, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» прошла бы мимо него.
  Future<void> onSearchSubmitted(String value) async {
    final input = value.trim();
    if (input.isEmpty || !_deduper.allow(input)) return;
    final cubit = context.read<GoodsListCubit>();
    cubit
        .cancelPendingSearch(); // ввод завершён — отложенный поиск уже не нужен
    // Ячейка и короб открывают своё содержимое (P5-05). Адрес, которого нет в справочнике
    // ячеек, остаётся текстом поиска — так ищут товар по фрагменту с дефисом.
    final opened = await openScannedContents(
      context,
      ScanCode(raw: input),
      unknownCellIsMine: false,
    );
    if (opened || !mounted) return;
    if (!looksLikeBarcode(input)) {
      showInSearchField(input);
      await cubit.setQuery(input);
      return;
    }

    final resolved = await cubit.resolveBarcode(input);
    if (!mounted) return;
    if (resolved.isLeft) {
      // Офлайн и отказ сервера — разные вещи, и путать их нельзя: «не найден по локальной базе»
      // кладовщик может доверить своей памяти, «не удалось проверить» — повод позвать админа.
      final failure = resolved.left;
      snack(
        failure is NetworkFailure
            ? t.stockListScreen.barcodeOffline(barcode: input)
            : t.stockListScreen.barcodeLookupFailed(barcode: input),
      );
      return;
    }
    final good = resolved.right;
    if (good != null) {
      openGoodDetail(good);
      return;
    }
    await offerBinding(input);
  }

  /// Показать в строке поиска текст, который применён к списку.
  ///
  /// В intent-режиме код приходит мимо поля — [onHardwareScan] зовёт обработчик напрямую, минуя
  /// контроллер. Без этого экран отвечал «товары не найдены» при пустой строке поиска: причину
  /// не видно, крестика очистки нет (он показывается по непустому полю), и поле со списком
  /// говорят разное (ADHOC-06).
  void showInSearchField(String text) {
    if (_searchController.text == text) return;
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// ШК не привязан ни к одному товару: спрашиваем → выбор товара → привязка → его карточка.
  ///
  /// Сюда попадаем только когда связь есть: привязка пишется на сервер (очереди операций ещё
  /// нет, это P2-03), а офлайн-резолв заканчивается сообщением «нет связи» и до этого шага
  /// не доходит.
  Future<void> offerBinding(String barcode) async {
    final confirmed = await showBindPromptDialog(
      context,
      title: t.stockListScreen.bindPromptTitle,
      body: t.stockListScreen.bindPromptBody(barcode: barcode),
      confirmLabel: t.stockListScreen.bindConfirm,
      cancelLabel: t.stockListScreen.bindCancel,
    );
    if (!confirmed || !mounted) return;
    final good = await pickGood();
    if (good == null || !mounted) return;
    final failure = await context.read<GoodsListCubit>().bindBarcode(
      goodId: good.id,
      barcode: barcode,
    );
    if (!mounted) return;
    if (failure != null) {
      snack(t.stockListScreen.bindFailed);
      return;
    }
    openGoodDetail(good);
  }

  /// Нижний лист выбора товара из номенклатуры; null — лист закрыли, ничего не выбрав.
  Future<Good?> pickGood() => showModalBottomSheet<Good>(
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.95,
    ),
    builder: (_) => GoodPickerSheet(repo: getIt<CatalogRepository>()),
  );

  /// Короткое сообщение поверх списка. Предыдущее гасим: сканы идут подряд, иначе очередь
  /// SnackBar'ов показывала бы ответы на давно отсканированные коды.
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Код с аппаратного сканера (intent-режим). На «Товарах» ведём тем же путём, что и
  /// завершённый ввод в строке поиска — ШК открывает карточку, прочее ищется подстрокой.
  @override
  void onHardwareScan(ScanCode code) =>
      _tab == 1 ? onBoxScan(code) : onSearchSubmitted(code.raw);

  /// Скан на вкладке «Короба»: QR короба и этикетка ячейки открывают их, прочее — не короб.
  Future<void> onBoxScan(ScanCode code) async {
    if (!_deduper.allow(code.raw)) return;
    if (await openScannedContents(context, code)) return;
    if (mounted) snack(t.contents.notCellOrBox);
  }

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
    _boxController.dispose();
    super.dispose();
  }

  /// Строка поиска «Товаров» и компактная кнопка фильтров (с бейджем активных).
  Widget _goodsSearch() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: SearchField(
              hintText: t.stockListScreen.searchHint,
              controller: _searchController,
              onChanged: onSearchChanged,
              onSubmitted: onSearchSubmitted,
              onClear: clearSearch,
            ),
          ),
          AppBoxes.kWidth8,
          const FilterButton(),
        ],
      ),
      const ActiveChips(),
    ],
  );

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
              goBack: goBack,
              openStockEntry: () => openStockEntry(context),
              search: _tab == 0 ? _goodsSearch() : _boxesSearch(),
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
