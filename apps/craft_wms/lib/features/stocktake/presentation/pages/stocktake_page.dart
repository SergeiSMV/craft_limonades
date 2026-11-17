import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/auth/rights.dart';
import '../../../../core/auth/session_rights.dart';
import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/failure_reason.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/stocktake_models.dart';
import '../bloc/stocktake_cells_cubit.dart';
import '../widgets/stocktake_cells_list.dart';
import '../widgets/stocktake_dialogs.dart';
import '../../../../core/utils/doc_number.dart';

/// Ячейки пересчёта (P10-04): свои и свободные; скан ячейки на месте начинает её подсчёт.
/// Старшему смены - закрыть пересчёт. Без связи - только начатые подсчёты на терминале.
@RoutePage()
class StocktakePage extends StatelessWidget {
  const StocktakePage({super.key, required this.stocktakeId, this.number});

  final String stocktakeId;

  /// Номер пересчёта для заголовка, пока ход не загружен.
  final int? number;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StocktakeCellsCubit>(param1: stocktakeId)..load(),
      child: _StocktakeView(number: number),
    );
  }
}

class _StocktakeView extends StatefulWidget {
  const _StocktakeView({this.number});

  final int? number;

  @override
  State<_StocktakeView> createState() => _StocktakeViewState();
}

class _StocktakeViewState extends State<_StocktakeView>
    with HardwareScanListener {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  StocktakeCellsCubit get cubit => context.read<StocktakeCellsCubit>();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Скан ячейки на месте: свободная берётся и начинается, своя - начинается.
  Future<void> onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isNotEmpty && _deduper.allow(code)) {
      if (classifyScan(code) == ScanKind.cell) {
        await cubit.scanCell(code);
      } else {
        snack(t.stocktake.scanCellHint);
      }
    }
    refocusScan();
  }

  /// Касание ячейки: свободную - взять; свою - отказаться (начинает её только скан на месте).
  Future<void> onTapCell(StocktakeCell cell) async {
    if (cell.isFree) {
      await cubit.take(cell);
    } else if (await confirmRelease(context)) {
      await cubit.release(cell);
    }
    refocusScan();
  }

  /// Открыть подсчёт; по возврату список обновляется - ячейка могла уйти в «подсчитана».
  Future<void> openCount(StocktakeCellView view) async {
    await context.router.push(StocktakeCountRoute(view: view));
    await cubit.load();
    refocusScan();
  }

  /// Закрыть пересчёт - с подтверждением; неподсчитанные ячейки называются числом.
  Future<void> closeStocktake() async {
    final info = cubit.state.info;
    if (info == null) return;
    final uncounted = info.cells.length - info.counted;
    if (await confirmClose(context, uncounted: uncounted)) {
      await cubit.closeStocktake(force: uncounted > 0);
    }
  }

  void goBack() => context.router.maybePop();

  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Подсказки и переход к подсчёту.
  void onState(BuildContext context, StocktakeCellsState state) {
    final started = state.started;
    if (started != null) {
      cubit.clearStarted();
      openCount(started);
      return;
    }
    final n = state.notice;
    if (n == null) return;
    cubit.clearNotice();
    switch (n) {
      case CellsNoticeNotHere(:final address):
        snack(t.stocktake.notHere(address: address));
      case CellsNoticeTaken(:final address):
        snack(t.stocktake.taken(address: address));
      case CellsNoticeFailed(:final failure):
        snack(
          failure is NetworkFailure
              ? t.stocktake.needsConnection
              : t.stocktake.actionFailed(reason: failureReason(failure)),
        );
      case CellsNoticeClosed():
        snack(t.stocktake.closed);
        goBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Закрыть пересчёт - право «заводить и закрывать» (ADHOC-51).
    final canManage = sessionCan(context, Rights.tsdStocktakeManage);
    return BlocConsumer<StocktakeCellsCubit, StocktakeCellsState>(
      listenWhen: (a, b) =>
          (b.notice != null && a.notice != b.notice) ||
          (b.started != null && a.started != b.started),
      listener: onState,
      builder: (context, state) {
        final number = state.info?.number ?? widget.number;
        return SystemUiWrapper(
          style: StatusBarStyle.light,
          child: Scaffold(
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
                title: number == null
                    ? t.stocktake.titlePlain
                    : t.stocktake.title(number: docNumber(DocKind.stocktake, number)),
                goBack: goBack,
              ),
            ),
            body: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: AppInsets.h8 + AppInsets.v16,
                    child: ScanField(
                      controller: _scanController,
                      focusNode: _scanFocus,
                      hint: t.stocktake.scanCellHint,
                      onSubmitted: onScan,
                    ),
                  ),
                  Expanded(
                    child: StocktakeCellsList(
                      state: state,
                      onRetry: cubit.load,
                      onTapCell: onTapCell,
                      onOpenDraft: openCount,
                    ),
                  ),
                  if (canManage && state.info != null && !state.info!.closed)
                    Padding(
                      padding: AppInsets.all16,
                      child: NeumorphicActionStack(
                        buttons: [
                          NeumorphicActionButton(
                            label: t.stocktake.close,
                            icon: MdiIcons.clipboardCheckOutline,
                            onPressed: closeStocktake,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
