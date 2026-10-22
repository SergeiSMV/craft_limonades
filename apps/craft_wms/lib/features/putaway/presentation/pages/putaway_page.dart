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
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../../tasks/data/tasks_models.dart';
import '../../../tasks/presentation/widgets/common/task_format.dart';
import '../bloc/putaway_cubit.dart';
import '../bloc/putaway_models.dart';
import '../widgets/pick_card.dart';
import '../widgets/putaway_lists.dart';
import '../widgets/putaway_messages.dart';

/// Выполнение задания на размещение (P5-03): скан короба или товара → скан ячейки → … →
/// «Завершить». Работает без связи: сеанс копится на терминале и уходит одной операцией.
@RoutePage()
class PutawayPage extends StatelessWidget {
  const PutawayPage({super.key, required this.task});

  final WarehouseTask task;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<PutawayCubit>(param1: task)..init(),
      child: const _PutawayView(),
    );
  }
}

class _PutawayView extends StatefulWidget {
  const _PutawayView();

  @override
  State<_PutawayView> createState() => _PutawayViewState();
}

class _PutawayViewState extends State<_PutawayView> with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  PutawayCubit get cubit => context.read<PutawayCubit>();

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

  //* --- скан --- *//

  /// Единая точка для обоих источников кода (поле и интент), поэтому отсечение дубля здесь.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isEmpty || !_deduper.allow(code) || cubit.state.outcome != null) {
      refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        cubit.pickBox(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await onCellScan(code);
      case ScanKind.good:
        await onGoodScan(code);
      case ScanKind.unknown:
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.putaway.boxLabelUnsupported);
        } else {
          await onGoodScan(code);
        }
    }
    refocusScan();
  }

  /// Скан этикетки ячейки: адрес ищется в справочнике, а не принимается на веру.
  Future<void> onCellScan(String address) async {
    final res = await getIt<CatalogRepository>().listAllCells();
    if (!mounted) return;
    final a = address.toLowerCase();
    final cell = res
        .fold((_) => const <Cell>[], (cells) => cells)
        .where((c) => c.address.toLowerCase() == a)
        .firstOrNull;
    if (cell == null) {
      snack(t.putaway.cellNotFound(address: address));
      return;
    }
    cubit.placeIn(cell);
  }

  /// Скан штрихкода товара: товар ищется в задании; партия и количество — из задания.
  Future<void> onGoodScan(String code) async {
    final res = await getIt<CatalogRepository>().resolveGoodByBarcode(code);
    if (!mounted) return;
    if (res.isLeft) {
      snack(
        res.left is NetworkFailure
            ? t.putaway.barcodeOffline(code: code)
            : t.putaway.barcodeUnknown(code: code),
      );
      return;
    }
    final good = res.right;
    if (good == null) {
      snack(t.putaway.barcodeUnknown(code: code));
      return;
    }
    await pickLooseOf(good.id);
  }

  /// Взять россыпь товара: одна партия — сразу количество, несколько — сначала партия.
  Future<void> pickLooseOf(String goodId) async {
    final candidates = cubit.looseOf(goodId);
    if (candidates.isEmpty) {
      final inTask = cubit.state.task.items.any((i) => i.good?.id == goodId);
      cubit.looseUnavailable(inTask: inTask);
      return;
    }
    final chosen = candidates.length == 1
        ? candidates.single
        : await chooseBatch(candidates);
    if (chosen == null || !mounted) return;
    await pickLoose(chosen.$1, chosen.$2);
  }

  /// Выбрать партию из позиций задания этого товара.
  Future<(TaskItem, double)?> chooseBatch(List<(TaskItem, double)> options) =>
      showModalBottomSheet<(TaskItem, double)>(
        context: context,
        backgroundColor: AppColors.kNeumorphicBg,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(t.putaway.batchTitle)),
              for (final o in options)
                ListTile(
                  title: Text(o.$1.good?.name ?? ''),
                  subtitle: Text(
                    t.putaway.looseLeft(
                      date: batchDate(o.$1.productionDate ?? ''),
                      qty: qtyText('${o.$2}'),
                      uom: o.$1.good?.uom ?? '',
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop(o),
                ),
            ],
          ),
        ),
      );

  /// Спросить количество россыпи и взять её в руки.
  Future<void> pickLoose(TaskItem item, double left) async {
    final qty = await showQtyDialog(
      context,
      max: left,
      uom: item.good?.uom ?? '',
    );
    if (qty != null) cubit.pickLoose(item, qty);
    refocusScan();
  }

  /// Позиция россыпи из списка — касанием, без скана (товар без штрихкода).
  Future<void> onLooseTapped(TaskItem item) =>
      pickLoose(item, cubit.state.looseLeft(item));

  /// Короб из списка — касанием, без скана (затёртый ярлык).
  void onBoxTapped(TaskItem item) => cubit.pickBox(item.loadUnitId!);

  /// Выбрать ячейку вручную — тот же лист, что в приёмке и «Вводе остатков».
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
    if (cell != null && mounted) cubit.placeIn(cell);
    refocusScan();
  }

  //* --- завершение --- *//

  /// Завершить сеанс. Если в задании ещё что-то осталось — спросить: остаток вернётся в пул.
  Future<void> finish() async {
    final s = cubit.state;
    if (s.openBoxes.isNotEmpty || s.openLoose.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.putaway.finishPartialTitle),
          content: Text(t.putaway.finishPartialBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.putaway.finishPartialNo),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.putaway.finishPartialYes),
            ),
          ],
        ),
      );
      if (ok != true) {
        refocusScan();
        return;
      }
    }
    await cubit.submit();
  }

  /// Вернуться к заданию.
  void goBack() => context.router.maybePop();

  //* --- подсказки --- *//

  /// Показать подсказку по результату скана один раз.
  void onNotice(BuildContext context, PutawayState state) {
    final n = state.notice;
    if (n == null) return;
    snack(switch (n) {
      NoticeNotInTask() => t.putaway.noticeNotInTask,
      NoticeAlreadyPlaced() => t.putaway.noticeAlreadyPlaced,
      NoticePickFirst() => t.putaway.noticePickFirst,
      NoticeReceivingCell() => t.putaway.noticeReceivingCell,
      NoticeForeignCell() => t.putaway.noticeForeignCell,
      NoticePlaced(:final address) => t.putaway.noticePlaced(cell: address),
      NoticeReleaseOffline(:final number) => t.putaway.noticeReleaseOffline(
        number: number,
      ),
    });
    cubit.clearNotice();
  }

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PutawayCubit, PutawayState>(
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
              title: t.putaway.title(number: state.task.number),
              goBack: goBack,
            ),
          ),
          body: SafeArea(top: false, child: _body(state)),
        ),
      ),
    );
  }

  Widget _body(PutawayState state) {
    final foreign = state.foreignDraftNumber;
    if (foreign != null) {
      return ForeignDraftView(
        number: foreign,
        onDiscard: cubit.discardForeignDraft,
        onBack: goBack,
      );
    }
    final outcome = state.outcome;
    if (outcome != null) {
      return PutawayOutcomeView(
        outcome: outcome,
        reason: state.rejectReason,
        onDone: goBack,
        onFix: state.rejectedOperationId == null ? null : cubit.fixRejected,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.v16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.fixReason case final reason?) ...[
                RejectedSessionBanner(
                  text: t.putaway.fixReason(reason: reason),
                ),
                AppBoxes.kHeight8,
              ],
              ScanField(
                controller: _scanController,
                focusNode: _scanFocus,
                hint: state.pick == null
                    ? t.putaway.scanHint
                    : t.putaway.scanCellHint,
                onSubmitted: onScan,
              ),
              if (state.pick case final pick?) ...[
                AppBoxes.kHeight12,
                PickCard(
                  pick: pick,
                  onChooseCell: chooseCell,
                  onDrop: cubit.dropPick,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: PutawayLists(
            state: state,
            onPickBox: onBoxTapped,
            onPickLoose: onLooseTapped,
            onRemoveLine: cubit.removeLine,
          ),
        ),
        Padding(
          padding: AppInsets.all16,
          child: FilledButton(
            onPressed: state.canSubmit ? finish : null,
            child: state.busy
                ? const SizedBox.square(
                    dimension: AppSizes.kIcon18,
                    child: CircularProgressIndicator(
                      strokeWidth: AppSizes.kIcon2,
                    ),
                  )
                : Text(t.putaway.finish),
          ),
        ),
      ],
    );
  }
}
