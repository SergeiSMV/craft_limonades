import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../../core/widgets/neumorphic_action_button.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/scan_field.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../domain/stocktake_count.dart';
import '../../domain/stocktake_models.dart';
import '../bloc/stocktake_count_cubit.dart';
import '../widgets/count_finish_dialog.dart';
import '../widgets/count_outcome_view.dart';
import '../widgets/count_positions_list.dart';
import '../widgets/count_scan_actions.dart';
import '../widgets/line_menu_sheet.dart';

/// Подсчёт ячейки пересчёта (P10-04): слепой счёт по позициям снимка, «Ячейка посчитана».
///
/// Открывается после скана ячейки на месте (снимок снят сервером) или из начатого подсчёта на
/// терминале; дальше работает без связи - насчитанное живёт в черновике.
@RoutePage()
class StocktakeCountPage extends StatelessWidget {
  const StocktakeCountPage({super.key, required this.view});

  final StocktakeCellView view;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<StocktakeCountCubit>(param1: view)..restore(),
      child: const _CountView(),
    );
  }
}

class _CountView extends StatefulWidget {
  const _CountView();

  @override
  State<_CountView> createState() => _CountViewState();
}

class _CountViewState extends State<_CountView>
    with HardwareScanListener, CountScanActions {
  /// Имена внутренних складов для подписей; «Основной» не подписывается.
  Map<String, String> _warehouses = const {};

  @override
  void initState() {
    super.initState();
    _loadWarehouses();
  }

  Future<void> _loadWarehouses() async {
    final all = await getIt<InternalWarehouses>().all();
    if (!mounted) return;
    setState(() => _warehouses = {for (final w in all) w.id: w.name});
  }

  String? warehouseName(String? id) => id == null ? null : _warehouses[id];

  @override
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Вернуться к ячейкам.
  void goBack() => context.router.maybePop();

  /// Подсказка по результату скана - один раз.
  void onNotice(BuildContext context, StocktakeCountState state) {
    final n = state.notice;
    if (n == null) return;
    snack(switch (n) {
      CountNotice.boxAgain => t.stocktake.noticeBoxAgain,
      CountNotice.boxForeign => t.stocktake.noticeBoxForeign,
      CountNotice.markAgain => t.stocktake.noticeMarkAgain,
      CountNotice.scanMark => t.stocktake.noticeScanMark,
    });
    cubit.clearNotice();
  }

  /// Меню насчитанного: исправить (без марок) или убрать.
  Future<void> onLineMenu(CountLine line) async {
    final action = await showLineMenuSheet(
      context,
      canEdit: line.marks.isEmpty,
      removeLabel: t.stocktake.lineRemove,
    );
    if (!mounted || action == null) return;
    if (action == LineMenuAction.edit) {
      await editLine(line);
    } else {
      cubit.removeLine(line);
    }
    refocusScan();
  }

  /// Меню найденного короба: снять отметку.
  Future<void> onBoxMenu(CountBox box) async {
    final action = await showLineMenuSheet(
      context,
      canEdit: false,
      removeLabel: t.stocktake.boxRemove,
    );
    if (mounted && action == LineMenuAction.remove) cubit.removeBox(box);
    refocusScan();
  }

  /// «Ячейка посчитана»: подтвердить список не найденного и отправить.
  Future<void> finish() async {
    final ok = await showCountFinishDialog(context, count);
    if (ok && mounted) await cubit.submit();
    refocusScan();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<StocktakeCountCubit, StocktakeCountState>(
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
              title: t.stocktake.cellTitle(address: state.count.cell.address),
              goBack: goBack,
            ),
          ),
          body: SafeArea(top: false, child: _body(state)),
        ),
      ),
    );
  }

  Widget _body(StocktakeCountState state) {
    final outcome = state.outcome;
    if (outcome != null) {
      return CountOutcomeView(
        outcome: outcome,
        reason: state.rejectReason,
        onDone: goBack,
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
              ScanField(
                controller: scanController,
                focusNode: scanFocus,
                hint: t.stocktake.countHint,
                onSubmitted: onScan,
              ),
            ],
          ),
        ),
        Expanded(
          child: CountPositionsList(
            count: state.count,
            warehouseName: warehouseName,
            onTapPosition: countPosition,
            onLongPressLine: onLineMenu,
            onLongPressBox: onBoxMenu,
          ),
        ),
        Padding(
          padding: AppInsets.all16,
          child: NeumorphicActionStack(
            buttons: [
              NeumorphicActionButton(
                label: t.stocktake.addManual,
                icon: MdiIcons.plus,
                onPressed: addManual,
              ),
              if (state.history.isNotEmpty)
                NeumorphicActionButton(
                  label: t.stocktake.undo,
                  icon: MdiIcons.undo,
                  onPressed: cubit.undo,
                ),
              NeumorphicActionButton(
                label: t.stocktake.finish,
                icon: MdiIcons.checkAll,
                onPressed: state.submitting ? () {} : finish,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
