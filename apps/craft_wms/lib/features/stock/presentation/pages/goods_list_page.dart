import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/utils/barcode.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/appbar_image.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../data/catalog_models.dart';
import '../../data/catalog_repository.dart';
import '../bloc/goods_list_cubit.dart';
import '../widgets/goods_list/active_chips.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/widgets/pending_pass_badge.dart';
import '../widgets/goods_list/goods_result.dart';
import '../widgets/goods_list/search_field.dart';
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
                            PendingPassBadge(
                              child: InkWell(
                                onTap: () => openStockEntry(context),
                                child: Icon(
                                  MdiIcons.playlistPlus,
                                  size: AppSizes.kIcon30,
                                  color: AppColors.kNeumorphicBg,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      AppBoxes.kHeight16,
                      // Строка поиска + компактная кнопка фильтров (с бейджем активных).
                      Row(
                        children: [
                          Expanded(
                            child: GoodsSearchField(
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
}
