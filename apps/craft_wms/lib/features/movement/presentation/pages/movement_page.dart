import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/utils/keyboard.dart';
import '../../../../core/widgets/cell_change_sheet.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/qty_dialog.dart';
import '../../../../core/widgets/rejected_session_banner.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../../core/widgets/tab_switch.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../contents/domain/load_unit_label_printer.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/movement_cubit.dart';
import '../bloc/movement_history_cubit.dart';
import '../bloc/movement_state.dart';
import '../widgets/find_box_sheet.dart';
import '../widgets/history/move_history_feed.dart';
import '../widgets/history/move_history_filter_button.dart';
import '../widgets/move_goods_sheet.dart';
import '../widgets/move_hold_card.dart';
import '../widgets/move_lines_list.dart';
import '../widgets/move_manual_pick.dart';
import '../widgets/move_mark_scan_actions.dart';
import '../widgets/move_outcome_view.dart';
import '../widgets/move_qty_header.dart';

/// Перемещение (P6-04): взял (короб, товар из короба или из россыпи) → положил (ячейка или
/// короб) → … → «Завершить». Работает без связи: сеанс копится на терминале и уходит одной
/// операцией, а состав источников берётся из снимка содержимого склада.
///
/// Вкладки «Новое» и «Завершённые» (ADHOC-28), как в разделе «ЗАДАНИЯ»: «Завершённые» —
/// история перемещений всего склада, только онлайн, грузится при первом открытии вкладки.
@RoutePage()
class MovementPage extends StatelessWidget {
  const MovementPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<MovementCubit>()..init()),
        BlocProvider(create: (_) => getIt<MovementHistoryCubit>()),
      ],
      child: const _MovementView(),
    );
  }
}

class _MovementView extends StatefulWidget {
  const _MovementView();

  @override
  State<_MovementView> createState() => _MovementViewState();
}

class _MovementViewState extends State<_MovementView>
    with HardwareScanListener, MoveMarkScanActions {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();
  int _tab = 0;

  MovementCubit get cubit => context.read<MovementCubit>();
  ContentsRepository get contents => getIt<ContentsRepository>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  /// Вернуть фокус полю скана — иначе сканер в режиме «клавиатуры» печатает в никуда.
  void refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  //* --- вкладки --- *//

  /// Переключить вкладку; историю грузим при первом заходе в «Завершённые».
  void selectTab(int index) {
    setState(() => _tab = index);
    final history = context.read<MovementHistoryCubit>();
    if (index == 1 && history.state.status == HistoryStatus.initial) {
      history.load();
    }
    if (index == 0) refocusScan();
  }

  //* --- скан --- *//

  /// Единая точка для обоих источников кода (поле и интент), поэтому отсечение дубля здесь.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    // Скан на вкладке истории — кладовщик начал перемещать: возвращаемся к сеансу.
    if (_tab != 0) setState(() => _tab = 0);
    if (code.isEmpty || !_deduper.allow(code) || cubit.state.outcome != null) {
      refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        await onBoxScan(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await onCellScan(code);
      case ScanKind.good:
        await onGoodScan(code);
      case ScanKind.czBox:
        await onCzBoxScan(czBoxFrom(code)!);
      case ScanKind.czMark:
        await onMarkScan(czMarkFrom(code)!);
      case ScanKind.unknown:
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.movement.boxLabelUnsupported);
        } else {
          await onGoodScan(code);
        }
    }
    refocusScan();
  }

  /// Скан QR короба: карточка — с сервера или из снимка со своей очередью поверх; ячейка —
  /// та, куда короб перенесён в этом сеансе, иначе та, где он числится.
  Future<void> onBoxScan(String id) async {
    final res = await contents.loadUnit(id);
    if (!mounted) return;
    if (res.isLeft) {
      snack(t.movement.noData);
      return;
    }
    final box = res.right.value;
    if (box == null) {
      cubit.boxNotFound(offline: res.right.freshness is FromSnapshot);
      return;
    }
    await onBox(box);
  }

  /// Скан этикетки короба ЧЗ (`00`+SSCC, CZ-06): своего ярлыка у короба ЧЗ нет — ГЕ находится
  /// по коду, дальше всё как у скана QR.
  Future<void> onCzBoxScan(String czCode) async {
    final res = await contents.loadUnitIdByCzCode(czCode);
    if (!mounted) return;
    if (res.isLeft) {
      snack(t.movement.noData);
      return;
    }
    final id = res.right;
    if (id == null) {
      snack(t.czScan.boxNotReceived);
      return;
    }
    await onBoxScan(id);
  }

  /// Короб найден — сканом или вручную ([manual]). Ячейка — та, куда короб перенесён в этом
  /// сеансе, иначе та, где он числится.
  Future<void> onBox(LoadUnitView box, {bool manual = false}) async {
    final cellId = cubit.state.boxCellInSession(box.id) ?? box.cellId;
    final cell = cellId == null ? null : await cellWhere((c) => c.id == cellId);
    if (mounted) cubit.onBox(box, cell, manual: manual);
  }

  //* --- без скана: ярлык испорчен --- *//

  /// Найти короб по коду с ярлыка или адресу ячейки. Источником — с отметкой «выбран
  /// вручную» (предложить перепечатать ярлык); с товаром в руках — приёмником.
  Future<void> findBox() async {
    final box = await showFindBoxSheet(context, search: searchBoxes);
    await hideKeyboard();
    if (box != null && mounted) {
      await onBox(box, manual: cubit.state.hold is! HoldGoods);
    }
    refocusScan();
  }

  /// Поиск для листа «Найти короб»: по короткому коду — короба с таким кодом; по адресу
  /// ячейки — её короба. Адрес вроде «A-1-1» похож и на код, поэтому пробуем оба.
  Future<List<BoxSection>> searchBoxes(String query) async {
    final sections = <BoxSection>[];
    final code = shortCodeQuery(query);
    if (code != null) {
      final res = await contents.searchLoadUnits(code);
      final found = res.isRight
          ? res.right.value ?? const []
          : const <LoadUnitView>[];
      sections.add((t.movement.findBoxFound, found));
    }
    final a = query.toLowerCase();
    final cell = await cellWhere((c) => c.address.toLowerCase() == a);
    if (cell != null) {
      final res = await contents.cell(
        CellRef(id: cell.id, address: cell.address),
      );
      final boxes = res.isRight
          ? res.right.value?.loadUnits ?? const []
          : const <LoadUnitView>[];
      sections.add((t.movement.findBoxInCell(cell: cell.address), boxes));
    }
    return sections;
  }

  /// Перепечатать ярлык короба, выбранного вручную: испорченный меняют на месте.
  Future<void> reprintLabel() async {
    final hold = cubit.state.hold;
    final id = hold is HoldSource ? hold.place.loadUnitId : null;
    if (id == null) return;
    final error = await getIt<LoadUnitLabelPrinter>().printLabel(id);
    if (mounted) snack(error ?? t.movement.labelPrinted);
    refocusScan();
  }

  /// Скан этикетки ячейки: адрес ищется в справочнике, а не принимается на веру.
  Future<void> onCellScan(String address) async {
    final a = address.toLowerCase();
    final cell = await cellWhere((c) => c.address.toLowerCase() == a);
    if (!mounted) return;
    if (cell == null) {
      snack(t.movement.cellNotFound(address: address));
      return;
    }
    await onCell(cell);
  }

  /// Ячейка выбрана — сканом или из справочника. Её россыпь нужна, только если она становится
  /// источником: с коробом или товаром в руках ячейка — приёмник.
  Future<void> onCell(Cell cell) async {
    if (cubit.state.hold != null) {
      cubit.onCell(cell);
      return;
    }
    final res = await contents.cell(
      CellRef(id: cell.id, address: cell.address),
    );
    if (!mounted) return;
    if (res.isLeft) {
      snack(t.movement.noData);
      return;
    }
    cubit.onCell(cell, loose: res.right.value?.loose ?? const []);
  }

  /// Скан штрихкода товара: товар ищется в источнике в руках; партия и количество — оттуда.
  Future<void> onGoodScan(String code) async {
    if (cubit.state.hold is! HoldSource) {
      cubit.goodWithoutSource();
      return;
    }
    final res = await getIt<CatalogRepository>().resolveGoodByBarcode(code);
    if (!mounted) return;
    final good = res.isRight ? res.right : null;
    if (good == null) {
      snack(
        res.isLeft && res.left is NetworkFailure
            ? t.movement.barcodeOffline(code: code)
            : t.movement.barcodeUnknown(code: code),
      );
      return;
    }
    // Маркируемый товар берут марками (CZ-06): какие именно единицы, должно быть известно.
    if (good.czMarked) {
      cubit.markRequired();
      return;
    }
    await takeFrom(cubit.candidates(goodId: good.id));
  }

  /// Выбрать товар из источника — для товара без штрихкода.
  Future<void> chooseGood() async {
    await takeFrom(cubit.candidates());
    refocusScan();
  }

  /// Взять товар: одна партия — сразу количество, несколько — сначала партия. Количество по
  /// умолчанию — всё, что есть в источнике (решение 2026-10-13).
  Future<void> takeFrom(List<(ContentLine, double)> options) async {
    if (options.isEmpty) {
      cubit.goodNotInSource();
      return;
    }
    final chosen = options.length == 1
        ? options.single
        : await showMoveGoodsSheet(context, options);
    if (chosen == null || !mounted) return;
    final good = await getIt<CatalogRepository>().goodById(chosen.$1.goodId);
    if (!mounted) return;
    if (good?.czMarked ?? false) {
      cubit.markRequired();
      return;
    }
    final hold = cubit.state.hold;
    if (hold is! HoldSource) return;
    final qty = await showQtyDialog(
      context,
      max: chosen.$2,
      uom: chosen.$1.uom ?? '',
      title: t.movement.qtyTitle,
      header: MoveQtyHeader(
        line: chosen.$1,
        available: chosen.$2,
        from: hold.place,
      ),
    );
    if (qty != null) cubit.takeGoods(chosen.$1, qty);
    refocusScan();
  }

  /// Выбрать ячейку вручную — тот же лист, что в приёмке и размещении.
  Future<void> chooseCell() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      builder: (_) => const CellChangeSheet(),
    );
    // Поле поиска в листе могло открыть клавиатуру — на экране скана она не нужна.
    await hideKeyboard();
    if (cell != null && mounted) await onCell(cell);
    refocusScan();
  }

  /// Ячейка справочника терминала по условию; `null` — такой нет.
  @override
  Future<Cell?> cellWhere(bool Function(Cell) test) async {
    final res = await getIt<CatalogRepository>().listAllCells();
    return res
        .fold((_) => const <Cell>[], (cells) => cells)
        .where(test)
        .firstOrNull;
  }

  /// Вернуться в меню.
  void goBack() => context.router.maybePop();

  //* --- подсказки --- *//

  /// Показать подсказку по результату скана один раз.
  void onNotice(BuildContext context, MovementState state) {
    final n = state.notice;
    if (n == null) return;
    snack(switch (n) {
      NoticeSourceFirst() => t.movement.noticeSourceFirst,
      NoticePutFirst() => t.movement.noticePutFirst,
      NoticeNotInSource() => t.movement.noticeNotInSource,
      NoticeNoLoose() => t.movement.noticeNoLoose,
      NoticeBoxEmpty() => t.movement.noticeBoxEmpty,
      NoticeLabelInvalid() => t.movement.noticeLabelInvalid,
      NoticeBoxUnknownOffline() => t.movement.noticeBoxUnknownOffline,
      NoticeReceivingCell() => t.movement.noticeReceivingCell,
      NoticeForeignCell() => t.movement.noticeForeignCell,
      NoticeSameCell() => t.movement.noticeSameCell,
      NoticeSamePlace() => t.movement.noticeSamePlace,
      NoticeBoxIntoBox() => t.movement.noticeBoxIntoBox,
      NoticeWarehouseMismatch() => t.movement.noticeWarehouseMismatch,
      NoticeMoved(:final address) => t.movement.noticeMoved(cell: address),
      NoticeScanMark() => t.movement.noticeScanMark,
      NoticeMarkTaken() => t.movement.noticeMarkTaken,
      NoticeMarkOtherGoods() => t.movement.noticeMarkOtherGoods,
    });
    cubit.clearNotice();
  }

  @override
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MovementCubit, MovementState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) => SystemUiWrapper(
        style: StatusBarStyle.light,
        child: Scaffold(
          // Под клавиатуру экран не сжимается: текст здесь вводит только сканер, а диалоги
          // количества и выбора ячейки держат клавиатуру сами. Сжатие ломало вёрстку, стоило
          // клавиатуре остаться после листа выбора ячейки (переполнение снизу, DT50S).
          resizeToAvoidBottomInset: false,
          backgroundColor: AppColors.kNeumorphicBg,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: Colors.transparent,
            elevation: 0,
            toolbarHeight: AppSizes.kIcon60,
            flexibleSpace: ClipRRect(
              borderRadius: AppBorders.kBottom10,
              child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
            ),
            title: PageHeader(
              title: t.movement.title,
              goBack: goBack,
              trailing: _tab == 1 ? const MoveHistoryFilterButton() : null,
            ),
          ),
          body: SafeArea(top: false, child: _tabs(state)),
        ),
      ),
    );
  }

  /// Вкладки «Новое» / «Завершённые». Итог сеанса — во весь экран, без вкладок.
  Widget _tabs(MovementState state) {
    if (state.outcome != null) return _body(state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.top16,
          child: TabSwitch(
            labels: [t.movement.tabNew, t.movement.tabCompleted],
            selected: _tab,
            onSelected: selectTab,
            activeColor: AppColors.kTileMovement,
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [_body(state), const MoveHistoryFeed()],
          ),
        ),
      ],
    );
  }

  Widget _body(MovementState state) {
    final outcome = state.outcome;
    if (outcome != null) {
      return MoveOutcomeView(
        outcome: outcome,
        reason: state.rejectReason,
        onDone: goBack,
        onFix: state.rejectedOperationId == null ? null : cubit.fixRejected,
      );
    }
    final hold = state.hold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.v16, //AppInsets.all16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.fixReason case final reason?) ...[
                RejectedSessionBanner(
                  text: t.movement.fixReason(reason: reason),
                ),
                AppBoxes.kHeight8,
              ],
              ScanField(
                controller: _scanController,
                focusNode: _scanFocus,
                hint: hold == null
                    ? t.movement.scanHint
                    : t.movement.scanTargetHint,
                onSubmitted: onScan,
              ),
              if (hold == null) ...[
                AppBoxes.kHeight8,
                MoveManualPick(onChooseCell: chooseCell, onFindBox: findBox),
              ],
              if (hold != null) ...[
                AppBoxes.kHeight12,
                MoveHoldCard(
                  hold: hold,
                  onChooseGood: chooseGood,
                  onChooseCell: chooseCell,
                  onFindBox: findBox,
                  onReprint: reprintLabel,
                  onDrop: cubit.dropHold,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: MoveLinesList(lines: state.lines, onRemove: cubit.removeLine),
        ),
        Padding(
          padding: AppInsets.all16,
          child: FilledButton(
            onPressed: state.canSubmit ? cubit.submit : null,
            child: state.busy
                ? const SizedBox.square(
                    dimension: AppSizes.kIcon18,
                    child: CircularProgressIndicator(
                      strokeWidth: AppSizes.kIcon2,
                    ),
                  )
                : Text(t.movement.finish),
          ),
        ),
      ],
    );
  }
}
