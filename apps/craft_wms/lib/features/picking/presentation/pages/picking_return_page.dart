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
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/utils/doc_number.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../../core/widgets/error_retry.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/qty_dialog.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/section_title.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../../stock/domain/catalog_repository.dart';
import '../../../stocktake/presentation/widgets/cell_count_warning.dart';
import '../../domain/picking_return.dart';
import '../bloc/picking_return_cubit.dart';
import '../widgets/picking_return_tile.dart';

/// Возврат на места по заданию (P9-07-1): реестр изменил или удалил заказ после сборки.
///
/// Из короба отгрузки: скан короба → позиция (количество или марки) → скан ячейки хранения,
/// куда кладут. Взятое удалённого заказа, ещё у источника: позиция → скан её ячейки или короба.
@RoutePage()
class PickingReturnPage extends StatelessWidget {
  const PickingReturnPage({
    super.key,
    required this.orderId,
    required this.number,
  });

  final String orderId;

  /// Номер сборки «СБ-…» - для заголовка до ответа сервера.
  final int number;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<PickingReturnCubit>(param1: orderId)..load(),
      child: _PickingReturnView(number: number),
    );
  }
}

class _PickingReturnView extends StatefulWidget {
  const _PickingReturnView({required this.number});

  final int number;

  @override
  State<_PickingReturnView> createState() => _PickingReturnViewState();
}

class _PickingReturnViewState extends State<_PickingReturnView>
    with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  PickingReturnCubit get cubit => context.read<PickingReturnCubit>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  /// Вернуть фокус полю скана - иначе сканер в режиме «клавиатуры» печатает в никуда.
  void refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Единая точка для поля и интента сканера: короб, марка или ячейка.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) {
      refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        await cubit.scanLoadUnit(loadUnitIdFrom(code)!);
      case ScanKind.czMark:
        cubit.scanMark(czMarkFrom(code)!);
      default:
        await onCellScan(code);
    }
    refocusScan();
  }

  /// Скан ячейки: ячейка из справочника терминала; кладут в неё - остаток меняется, и ячейка
  /// на пересчёте сначала предупреждает (ADHOC-48).
  Future<void> onCellScan(String address) async {
    final a = address.toLowerCase();
    final cells = (await getIt<CatalogRepository>().listAllCells()).fold(
      (_) => const <Cell>[],
      (cells) => cells,
    );
    final cell = cells.where((c) => c.address.toLowerCase() == a).firstOrNull;
    if (!mounted) return;
    if (cell == null) {
      snack(t.pickingReturn.cellUnknown(cell: address));
      return;
    }
    if (cubit.state.selected?.moved == true &&
        !await allowMoveThroughCell(context, cell.id)) {
      return;
    }
    if (mounted) await cubit.scanCell(cell);
  }

  /// Касание позиции: немаркируемую из короба - сколько вернуть, остальные - выбрать.
  Future<void> onTapPick(PickingReturnPick p) async {
    final s = cubit.state;
    if (p.moved && !p.czMarked && s.boxId == p.boxId) {
      final qty = await showQtyDialog(
        context,
        max: s.available(p),
        uom: p.uom,
        title: t.pickingReturn.qtyTitle,
      );
      if (qty != null && mounted) cubit.select(p, qty: qty);
    } else {
      cubit.select(p);
    }
    refocusScan();
  }

  /// Вернуться к заданию.
  void goBack() => context.router.maybePop();

  /// Подсказка по результату - один раз; всё вернули - экран закрывается.
  void onNotice(BuildContext context, PickingReturnState state) {
    final n = state.notice;
    if (n == null) return;
    cubit.clearNotice();
    switch (n) {
      case ReturnNoticeDone():
        snack(t.pickingReturn.done);
        goBack();
        return;
      case ReturnNoticeFailed(:final failure):
        snack(
          failure is NetworkFailure
              ? t.pickingReturn.offline
              : t.pickingReturn.loadFailed(reason: failureReason(failure)),
        );
      case ReturnNoticeRejected(:final reason):
        snack(t.pickingReturn.rejected(reason: reason));
      case ReturnNoticeReturned(:final qty, :final cell):
        snack(t.pickingReturn.returned(qty: fmtQty(qty), cell: cell));
      case ReturnNoticeQueued():
        snack(t.pickingReturn.returnedQueued);
      case ReturnNoticeUnpicked():
        snack(t.pickingReturn.unpicked);
      case ReturnNoticeHint(:final hint, :final seq, :final source):
        snack(switch (hint) {
          ReturnHint.boxForeign => t.pickingReturn.boxForeign,
          ReturnHint.boxFirst => t.pickingReturn.boxFirst(seq: seq ?? 0),
          ReturnHint.markForeign => t.pickingReturn.markForeign,
          ReturnHint.markAgain => t.pickingReturn.markAgain,
          ReturnHint.chooseFirst => t.pickingReturn.chooseFirst,
          ReturnHint.cellDenied => t.pickingReturn.cellDenied,
          ReturnHint.sourceMismatch => t.pickingReturn.sourceMismatch(
            source: source ?? '',
          ),
        });
    }
  }

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PickingReturnCubit, PickingReturnState>(
      listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
      listener: onNotice,
      builder: (context, state) => SystemUiWrapper(
        style: StatusBarStyle.light,
        child: Scaffold(
          // Текст здесь вводит только сканер - под клавиатуру экран не сжимается.
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
              title: t.pickingReturn.title(
                number: docNumber(DocKind.picking, widget.number),
              ),
              goBack: goBack,
            ),
          ),
          body: SafeArea(top: false, child: _body(state)),
        ),
      ),
    );
  }

  Widget _body(PickingReturnState state) {
    final view = state.view;
    if (view == null) {
      if (state.status == PickingReturnStatus.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      final f = state.failure;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppInsets.h8 + AppInsets.v16,
            child: Text(
              f is NetworkFailure || f == null
                  ? t.pickingReturn.offline
                  : t.pickingReturn.loadFailed(reason: failureReason(f)),
              style: RegularTextStyles().regularInter14,
            ),
          ),
          Expanded(child: ErrorRetry(onRetry: cubit.load)),
        ],
      );
    }
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    final open = state.open;
    final moved = open.where((p) => p.moved).toList();
    final atSource = open.where((p) => !p.moved).toList();
    final seqs = {for (final p in moved) p.boxSeq}.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.v16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (view.invoiceNumber.isNotEmpty)
                Text(
                  t.picking.invoice(number: view.invoiceNumber),
                  style: muted,
                ),
              if (view.orderNumber.isNotEmpty)
                Text(t.picking.order(number: view.orderNumber), style: muted),
              if (view.client.isNotEmpty)
                Text(t.picking.client(name: view.client), style: muted),
              Text(
                view.deleted
                    ? t.pickingReturn.basisDeleted
                    : t.pickingReturn.basisChanged,
                style: muted,
              ),
              Text(t.pickingReturn.left(qty: fmtQty(state.left)), style: muted),
              AppBoxes.kHeight8,
              ScanField(
                controller: _scanController,
                focusNode: _scanFocus,
                hint: t.pickingReturn.scanHint,
                onSubmitted: onScan,
              ),
              AppBoxes.kHeight8,
              Text(
                _step(state, moved),
                style: RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kTileTasks,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: AppInsets.h8,
            children: [
              for (final seq in seqs) ...[
                SectionTitle(title: t.pickingReturn.sectionBox(seq: seq)),
                for (final p in moved.where((p) => p.boxSeq == seq))
                  _tile(state, p),
              ],
              if (atSource.isNotEmpty) ...[
                SectionTitle(title: t.pickingReturn.sectionOpen),
                for (final p in atSource) _tile(state, p),
              ],
              AppBoxes.kHeight16,
            ],
          ),
        ),
      ],
    );
  }

  Widget _tile(PickingReturnState state, PickingReturnPick p) => Padding(
    padding: AppInsets.bottom8,
    child: PickingReturnTile(
      pick: p,
      available: state.available(p),
      pending: state.pending[p.pickId] ?? 0,
      active: !p.moved || state.boxId == p.boxId,
      selected: state.pickId == p.pickId,
      onTap: () => onTapPick(p),
    ),
  );

  /// Что делать сейчас.
  String _step(PickingReturnState state, List<PickingReturnPick> moved) {
    final p = state.selected;
    if (p == null) {
      final box = moved.where((m) => m.boxId == state.boxId).firstOrNull;
      if (box != null) return t.pickingReturn.stepPick(seq: box.boxSeq);
      return moved.isNotEmpty
          ? t.pickingReturn.stepBox
          : t.pickingReturn.chooseFirst;
    }
    if (!p.moved) return t.pickingReturn.stepSource(source: p.sourceCell);
    if (p.czMarked && state.marks.isEmpty) {
      return t.pickingReturn.stepMarks(
        done: 0,
        total: fmtQty(state.available(p)),
      );
    }
    return t.pickingReturn.stepCell(qty: fmtQty(state.takingQty));
  }
}
