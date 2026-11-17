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
import '../../cz/domain/cz_scan.dart';
import '../../cz/presentation/bloc/cz_scan_cubit.dart';
import '../../cz/presentation/cz_scan_target.dart';
import '../domain/catalog_models.dart';
import '../domain/catalog_repository.dart';
import 'bloc/goods_list_cubit.dart';
import 'widgets/goods_list/active_chips.dart';
import 'widgets/goods_list/stock_filter_button.dart';

/// Поиск товаров со сканом ШК - общий для «Остатков» и «Номенклатуры» (ADHOC-33).
///
/// Что: строка поиска с фильтрами и разбор завершённого ввода - скан ячейки или короба
///      открывает их содержимое, ШК - карточку товара (не привязан - предложение привязать),
///      марка или короб «Честного знака» - по ответу ЧЗ (CZ-04), прочее ищется подстрокой.
/// Зачем: до ADHOC-33 всё это жило в «Остатках»; «Номенклатура» повторяет поведение их
///        вкладки «Товары», и копия разошлась бы с оригиналом при первой правке.
/// Как: подмешивается в стейт страницы, которая держит над собой [GoodsListCubit].
mixin GoodsSearchHandlers<T extends StatefulWidget> on State<T> {
  /// Дебаунс поиска живёт в `GoodsListCubit`, а не здесь: гасить его должны и обработчики
  /// из соседних виджетов (уход в карточку товара - в `GoodsResult`), а до поля стейта
  /// они не дотягиваются.

  /// Контроллер строки поиска: по нему показываем крестик очистки (только при непустом
  /// вводе) и чистим поле по тапу.
  final searchController = TextEditingController();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final deduper = ScanDeduper();

  /// Чтение марок и коробов «Честного знака» (CZ-04). Свой на экран: страницы поиска не
  /// держат его в дереве, а ответ нужен только здесь, чтобы решить, куда вести кладовщика.
  /// Заводится первым сканом марки: большинство заходов в поиск марок не сканирует.
  CzScanCubit? _czScan;
  CzScanCubit get czScan => _czScan ??= getIt<CzScanCubit>();

  /// Поиск с дебаунсом: не дёргаем API на каждый символ.
  void onSearchChanged(String value) =>
      context.read<GoodsListCubit>().setQueryDebounced(value);

  /// Ввод завершён: сканер шлёт строку целиком и Enter, на софт-клавиатуре это «Поиск».
  /// Скан ячейки или короба открывает их содержимое, скан ШК резолвим и сразу открываем
  /// карточку товара, обычный текст - ищем подстрокой.
  ///
  /// Единая точка для обоих источников кода, поэтому отсечение дубля стоит здесь: если бы оно
  /// сидело только на ветке потока, пара «поле + интент» прошла бы мимо него.
  Future<void> onSearchSubmitted(String value) async {
    final input = value.trim();
    if (input.isEmpty || !deduper.allow(input)) return;
    final cubit = context.read<GoodsListCubit>();
    cubit
        .cancelPendingSearch(); // ввод завершён - отложенный поиск уже не нужен
    // Марка или короб «Честного знака» (CZ-04) - раньше ячеек и ШК: код короба - сплошные
    // цифры и иначе ушёл бы в «ШК товара» с предложением привязать его к товару.
    // Принятый короб ЧЗ открывается карточкой ГЕ и без связи (CZ-06); не принятый - составом
    // по ЧЗ.
    final kind = classifyScan(input);
    if (kind == ScanKind.czBox &&
        await openScannedContents(context, ScanCode(raw: input))) {
      return;
    }
    if (!mounted) return;
    if (kind == ScanKind.czMark || kind == ScanKind.czBox) {
      await openCzCode(input);
      return;
    }
    // Ячейка и короб открывают своё содержимое (P5-05). Адрес, которого нет в справочнике
    // ячеек, остаётся текстом поиска - так ищут товар по фрагменту с дефисом.
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
      // Офлайн и отказ сервера - разные вещи, и путать их нельзя: «не найден по локальной базе»
      // кладовщик может доверить своей памяти, «не удалось проверить» - повод позвать админа.
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
  /// В intent-режиме код приходит мимо поля - [onHardwareScan] зовёт обработчик напрямую, минуя
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

  /// Скан марки или кода короба «Честного знака» (CZ-04): сервер читает ЧЗ, по ответу -
  /// марка товара → его карточка с блоком марки; марка незнакомого товара → привязка ШК, как у
  /// любого незнакомого ШК; принятый короб → карточка ГЕ; прочая упаковка → состав по ЧЗ.
  ///
  /// Только со связью: ЧЗ без неё не читается - так кладовщику и говорим.
  Future<void> openCzCode(String code) async {
    if (czScan.state.status == CzScanStatus.loading) return;
    snack(t.czScan.reading);
    await czScan.scan(code);
    if (!mounted) return;
    final state = czScan.state;
    czScan.reset();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final r = state.result;
    if (r == null) {
      snack(czFailureText(state.failure));
      return;
    }
    switch (czScanTarget(r)) {
      case CzScanTarget.goodCard:
        await openCzMarkGood(r);
      case CzScanTarget.bindBarcode:
        // Незнакомый GTIN - тот же путь, что незнакомый ШК: наименование на марке может не
        // совпадать с номенклатурой, товар определяет привязка ШК (EAN-13 из GTIN).
        await offerBinding(r.bindBarcode!, czMark: r);
      case CzScanTarget.noGtin:
        snack(t.czScan.noGtin);
      case CzScanTarget.loadUnit:
        clearSearch();
        dismissKeyboard();
        await context.router.push(LoadUnitRoute(loadUnitId: r.loadUnitId!));
      case CzScanTarget.composition:
        clearSearch();
        dismissKeyboard();
        await context.router.push(CzCompositionRoute(scan: r));
    }
  }

  /// Марка известного товара - его карточка с блоком марки. Товар берётся из справочника
  /// терминала: карточке нужен он целиком, сервер его только называет.
  Future<void> openCzMarkGood(CzScanResult r) async {
    final found = await context.read<GoodsListCubit>().goodById(r.good!.id);
    if (!mounted) return;
    if (found == null) {
      snack(t.czScan.goodNotLoaded);
      return;
    }
    openGoodDetail(found, czMark: r);
  }

  /// Текст отказа чтения ЧЗ: без связи - отдельно, отказ сервера - его словами.
  String czFailureText(Failure? f) => switch (f) {
    NetworkFailure() => t.czScan.offline,
    ServerFailure(:final message?) => t.czScan.failed(reason: message),
    _ => t.czScan.failedGeneric,
  };

  /// ШК не привязан ни к одному товару: спрашиваем → выбор товара → привязка → его карточка.
  /// [czMark] - ШК пришёл из марки «Честного знака» (CZ-04): вопрос называет марку, а карточка
  /// откроется с её блоком.
  ///
  /// Сюда попадаем только когда связь есть: привязка пишется на сервер (очереди операций ещё
  /// нет, это P2-03), а офлайн-резолв заканчивается сообщением «нет связи» и до этого шага
  /// не доходит.
  Future<void> offerBinding(String barcode, {CzScanResult? czMark}) async {
    final confirmed = await showBindPromptDialog(
      context,
      title: czMark != null
          ? t.czScan.bindPromptTitle
          : t.stockListScreen.bindPromptTitle,
      body: czMark != null
          ? t.czScan.bindPromptBody(
              name: czMark.productName ?? czMark.code,
              barcode: barcode,
            )
          : t.stockListScreen.bindPromptBody(barcode: barcode),
      confirmLabel: t.stockListScreen.bindConfirm,
      cancelLabel: t.stockListScreen.bindCancel,
    );
    if (!confirmed || !mounted) return;
    final good = await pickGood();
    if (good == null || !mounted) return;
    final failure = await context.read<GoodsListCubit>().bindBarcode(
      goodId: good.id,
      barcode: barcode,
      fromCzMark: czMark != null,
    );
    if (!mounted) return;
    if (failure != null) {
      snack(t.stockListScreen.bindFailed);
      return;
    }
    // Товар выбран из списка до привязки - признак «маркируемый» в нём ещё прежний.
    openGoodDetail(
      czMark != null ? good.copyWith(czMarked: true) : good,
      czMark: czMark,
    );
  }

  /// Нижний лист выбора товара из номенклатуры; null - лист закрыли, ничего не выбрав.
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
  /// [czMark] - карточка открыта сканом марки «Честного знака»: с блоком марки (CZ-04).
  void openGoodDetail(Good good, {CzScanResult? czMark}) {
    final cubit = context.read<GoodsListCubit>();
    clearSearch();
    dismissKeyboard();
    // По возврату «Остатки» перечитывают снимок, обновлённый карточкой (ADHOC-33).
    context.router
        .push(StockDetailRoute(good: good, czMark: czMark))
        .then((_) => cubit.returnedFromCard(good.id));
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
    _czScan?.close();
    super.dispose();
  }
}
