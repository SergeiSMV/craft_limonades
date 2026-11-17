import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

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
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../stock/domain/catalog_models.dart';
import '../../../stock/domain/catalog_repository.dart';
import '../../../stocktake/presentation/widgets/cell_count_warning.dart';
import '../../../tasks/data/tasks_models.dart';
import '../bloc/supplier_return_cubit.dart';
import '../widgets/return_outcome_view.dart';
import '../widgets/return_position_tile.dart';
import '../../../../core/utils/doc_number.dart';

/// Отгрузка возврата поставщику по заданию (ADHOC-31): отметить все позиции - сканом короба,
/// ячейки и товара или касанием - и нажать «Отгружено». Задание отгружается целиком, сеанс
/// уходит одной операцией очереди и работает без связи.
@RoutePage()
class SupplierReturnPage extends StatelessWidget {
  const SupplierReturnPage({super.key, required this.task});

  final WarehouseTask task;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<SupplierReturnCubit>(param1: task),
      child: const _SupplierReturnView(),
    );
  }
}

class _SupplierReturnView extends StatefulWidget {
  const _SupplierReturnView();

  @override
  State<_SupplierReturnView> createState() => _SupplierReturnViewState();
}

class _SupplierReturnViewState extends State<_SupplierReturnView>
    with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  SupplierReturnCubit get cubit => context.read<SupplierReturnCubit>();

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

  /// Единая точка для поля и интента сканера: короб - сразу, ячейка - запоминается, товар -
  /// ищется по штрихкоду в справочнике терминала.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isEmpty || !_deduper.allow(code) || cubit.state.outcome != null) {
      refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        cubit.scanBox(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await onCellScan(code);
      case ScanKind.good:
        await onGoodScan(code);
      case ScanKind.czBox:
        cubit.scanCzBox(czBoxFrom(code)!);
      case ScanKind.czMark:
        cubit.scanMark(czMarkFrom(code)!);
      case ScanKind.unknown:
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.supplierReturn.boxLabelUnsupported);
        } else {
          await onGoodScan(code);
        }
    }
    refocusScan();
  }

  /// Скан ячейки: товар возврата забирают из неё, и это меняет её остаток - ячейка на
  /// пересчёте сначала предупреждает (ADHOC-48). Адрес не из справочника - проверять нечего,
  /// подсказку даст задание.
  Future<void> onCellScan(String address) async {
    final a = address.toLowerCase();
    final cells = (await getIt<CatalogRepository>().listAllCells()).fold(
      (_) => const <Cell>[],
      (cells) => cells,
    );
    final cell = cells.where((c) => c.address.toLowerCase() == a).firstOrNull;
    if (!mounted) return;
    if (cell != null &&
        !cell.isDefault &&
        !await allowMoveThroughCell(context, cell.id)) {
      return;
    }
    if (mounted) cubit.scanCell(address);
  }

  /// Скан штрихкода товара: товар - из справочника терминала, позиция - из задания.
  Future<void> onGoodScan(String code) async {
    final res = await getIt<CatalogRepository>().resolveGoodByBarcode(code);
    if (!mounted) return;
    final good = res.isRight ? res.right : null;
    if (good == null) {
      snack(
        res.isLeft && res.left is NetworkFailure
            ? t.supplierReturn.barcodeOffline(code: code)
            : t.supplierReturn.barcodeUnknown(code: code),
      );
      return;
    }
    cubit.scanGood(good.id);
  }

  /// Отметить позицию касанием.
  void onTapItem(TaskItem item) {
    cubit.toggle(item);
    refocusScan();
  }

  /// «Отгружено» - только когда отмечено всё; иначе подсказка, сколько осталось.
  Future<void> ship() async {
    final s = cubit.state;
    if (!s.complete) {
      snack(t.supplierReturn.notAll(left: s.open.length - s.marked.length));
      refocusScan();
      return;
    }
    await cubit.submit();
  }

  /// Вернуться к заданию.
  void goBack() => context.router.maybePop();

  /// Подсказка по результату скана - один раз.
  void onNotice(BuildContext context, SupplierReturnState state) {
    final n = state.notice;
    if (n == null) return;
    snack(switch (n) {
      ReturnNotice.notInTask => t.supplierReturn.noticeNotInTask,
      ReturnNotice.boxNotInTask => t.supplierReturn.noticeBoxNotInTask,
      ReturnNotice.alreadyChecked => t.supplierReturn.noticeAlreadyChecked,
      ReturnNotice.cellNotInTask => t.supplierReturn.noticeCellNotInTask,
      ReturnNotice.needCell => t.supplierReturn.noticeNeedCell(
        cell: state.noticeCell ?? '',
      ),
      ReturnNotice.scanMark => t.supplierReturn.noticeScanMark,
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
    return BlocConsumer<SupplierReturnCubit, SupplierReturnState>(
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
              title: t.supplierReturn.title(
                number: docNumber(DocKind.task, state.task.number),
              ),
              goBack: goBack,
            ),
          ),
          body: SafeArea(top: false, child: _body(state)),
        ),
      ),
    );
  }

  Widget _body(SupplierReturnState state) {
    final outcome = state.outcome;
    if (outcome != null) {
      return ReturnOutcomeView(
        outcome: outcome,
        reason: state.rejectReason,
        onDone: goBack,
      );
    }
    final muted = RegularTextStyles().regularInter14.copyWith(
      color: AppColors.kTextMuted,
    );
    final open = state.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: AppInsets.h8 + AppInsets.v16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.supplierReturn.supplier(name: state.task.supplier),
                style: RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kTextMain,
                ),
              ),
              AppBoxes.kHeight8,
              ScanField(
                controller: _scanController,
                focusNode: _scanFocus,
                hint: t.supplierReturn.scanHint,
                onSubmitted: onScan,
              ),
              AppBoxes.kHeight8,
              Text(
                t.supplierReturn.progress(
                  done: state.marked.length,
                  total: open.length,
                ),
                style: muted,
              ),
              // Что делать сейчас: без ячейки - сканировать ячейку (короб - только если в задании
              // есть короб целиком), с ячейкой - товар в ней.
              Text(
                state.cell != null
                    ? t.supplierReturn.stepGoods(cell: state.cell!)
                    : open.any(
                        (it) =>
                            it.isBox && !state.marked.contains(it.problemId),
                      )
                    ? t.supplierReturn.stepPlace
                    : t.supplierReturn.stepCell,
                style: RegularTextStyles().regularInter14.copyWith(
                  color: AppColors.kTileTasks,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: open.isEmpty
              ? Center(child: Text(t.supplierReturn.empty, style: muted))
              : ListView.separated(
                  padding: AppInsets.h8,
                  itemCount: open.length,
                  separatorBuilder: (_, _) => AppBoxes.kHeight8,
                  itemBuilder: (_, i) => ReturnPositionTile(
                    item: open[i],
                    checked: state.marked.contains(open[i].problemId),
                    active: state.isActive(open[i]),
                    scannedMarks: state.scannedOf(open[i]),
                    onTap: () => onTapItem(open[i]),
                  ),
                ),
        ),
        Padding(
          padding: AppInsets.all16,
          child: NeumorphicActionStack(
            buttons: [
              NeumorphicActionButton(
                label: t.supplierReturn.ship,
                icon: MdiIcons.truckCheckOutline,
                onPressed: ship,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
