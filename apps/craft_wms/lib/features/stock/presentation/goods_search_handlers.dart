import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../core/constants/app_boxes.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/di/injection.dart';
import '../../../core/error/failure.dart';
import '../../../core/gen/strings.g.dart';
import '../../../core/router/app_router.dart';
import '../../../core/scanner/scan_code.dart';
import '../../../core/scanner/scan_deduper.dart';
import '../../../core/utils/barcode.dart';
import '../../../core/utils/keyboard.dart';
import '../../../core/widgets/bind_prompt_dialog.dart';
import '../../../core/widgets/good_picker_sheet.dart';
import '../../../core/widgets/search_field.dart';
import '../../contents/presentation/contents_navigation.dart';
import '../data/catalog_models.dart';
import '../data/catalog_repository.dart';
import 'bloc/goods_list_cubit.dart';
import 'widgets/goods_list/active_chips.dart';
import 'widgets/goods_list/stock_filter_button.dart';

/// Поиск товаров со сканом ШК — общий для «Остатков» и «Номенклатуры» (ADHOC-33).
///
/// Что: строка поиска с фильтрами и разбор завершённого ввода — скан ячейки или короба
///      открывает их содержимое, ШК — карточку товара (не привязан — предложение привязать),
///      прочее ищется подстрокой.
/// Зачем: до ADHOC-33 всё это жило в «Остатках»; «Номенклатура» повторяет поведение их
///        вкладки «Товары», и копия разошлась бы с оригиналом при первой правке.
/// Как: подмешивается в стейт страницы, которая держит над собой [GoodsListCubit].
mixin GoodsSearchHandlers<T extends StatefulWidget> on State<T> {
  /// Дебаунс поиска живёт в `GoodsListCubit`, а не здесь: гасить его должны и обработчики
  /// из соседних виджетов (уход в карточку товара — в `GoodsResult`), а до поля стейта
  /// они не дотягиваются.

  /// Контроллер строки поиска: по нему показываем крестик очистки (только при непустом
  /// вводе) и чистим поле по тапу.
  final searchController = TextEditingController();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final deduper = ScanDeduper();

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
    if (input.isEmpty || !deduper.allow(input)) return;
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
    if (searchController.text == text) return;
    searchController.value = TextEditingValue(
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

  /// Открыть карточку товара, найденного по скану. Строку поиска чистим: иначе следующий
  /// скан допишется к предыдущему коду, а список остался бы несогласован с полем.
  void openGoodDetail(Good good) {
    final cubit = context.read<GoodsListCubit>();
    clearSearch();
    dismissKeyboard();
    // По возврату «Остатки» перечитывают снимок, обновлённый карточкой (ADHOC-33).
    context.router
        .push(StockDetailRoute(good: good))
        .then((_) => cubit.returnedFromCard());
  }

  /// Очистить строку поиска и сразу сбросить запрос. Отложенный дебаунс гасим: иначе
  /// «висящий» таймер применил бы старый текст уже после очистки.
  void clearSearch() {
    searchController.clear();
    context.read<GoodsListCubit>().setQuery(
      '',
    ); // setQuery сам гасит отложенный поиск
  }

  /// Строка поиска товаров и компактная кнопка фильтров (с бейджем активных).
  Widget goodsSearch() => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: SearchField(
              hintText: t.stockListScreen.searchHint,
              controller: searchController,
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

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }
}
