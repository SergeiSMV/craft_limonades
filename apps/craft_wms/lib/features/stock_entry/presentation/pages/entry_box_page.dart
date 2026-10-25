import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_borders.dart';
import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/assets.gen.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/theme/semibold_text.dart';
import '../../../../core/widgets/bar_buttons.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../cz/presentation/widgets/cz_intake_scan.dart';
import '../bloc/stock_entry_cubit.dart';
import '../widgets/entry_scan_actions.dart';
import '../widgets/entry_scan_field.dart';
import '../widgets/line_tile.dart';

/// Страница короба ячейки прохода (ADHOC-46): только содержимое этого короба.
///
/// Здесь сканы ложатся в короб, отсюда печатают его ярлык и удаляют короб. Отдельная
/// страница, а не переключатель «текущий короб» — тот же приём, что у приёмки (ADHOC-18):
/// переключатель легко забыть, и товар молча уезжал бы не в тот короб. Ячейка у короба —
/// ячейка прохода: короб переезжает только вместе с ней.
///
/// Cubit приходит от экрана ячейки: короб — часть того же прохода и его черновика.
@RoutePage()
class EntryBoxPage extends StatelessWidget {
  const EntryBoxPage({super.key, required this.cubit, required this.boxId});

  final StockEntryCubit cubit;
  final String boxId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: cubit,
      child: _EntryBoxView(boxId: boxId),
    );
  }
}

class _EntryBoxView extends StatefulWidget {
  const _EntryBoxView({required this.boxId});

  final String boxId;

  @override
  State<_EntryBoxView> createState() => _EntryBoxViewState();
}

class _EntryBoxViewState extends State<_EntryBoxView>
    with HardwareScanListener, CzIntakeScan, EntryScanActions<_EntryBoxView> {
  /// Строки этой страницы ложатся в короб.
  @override
  String? get scanBoxId => widget.boxId;

  /// Ярлык другого короба этой ячейки — переходим в него, не возвращаясь в ячейку: так
  /// раскладывают товар по нескольким коробам подряд.
  @override
  void onBoxScanned(String boxId) {
    if (boxId == widget.boxId) {
      snack(t.stockEntry.boxAlreadyOpen);
      return;
    }
    context.router.replace(EntryBoxRoute(cubit: cubit, boxId: boxId));
  }

  /// Напечатать ярлык короба и сказать, чем кончилось.
  Future<void> _printLabel() async {
    final error = await cubit.printBoxLabel(widget.boxId);
    if (!mounted) return;
    snack(
      error == null
          ? t.stockEntry.printed
          : t.stockEntry.printFailed(message: error),
    );
    refocusScan();
  }

  /// Удалить короб с позициями — после подтверждения: ярлык уже мог быть напечатан.
  Future<void> _deleteBox() async {
    final ok = await showBindPromptDialog(
      context,
      title: t.stockEntry.boxDeleteTitle,
      body: t.stockEntry.boxDeleteBody(
        count: cubit.state.linesOf(widget.boxId).length,
      ),
      confirmLabel: t.stockEntry.boxDeleteConfirm,
      cancelLabel: t.stockEntry.cancel,
    );
    if (!ok || !mounted) return;
    cubit.removeBox(widget.boxId);
    context.router.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StockEntryCubit>().state;
    final box = state.boxById(widget.boxId);
    // Короб удалён — страница уже закрывается, рисовать нечего.
    if (box == null) return const SizedBox.shrink();
    final lines = state
        .linesOf(box.id)
        .reversed
        .toList(); // свежая строка — сверху
    return SystemUiWrapper(
      style: StatusBarStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.kNeumorphicBg,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: AppSizes.kIcon60,
          flexibleSpace: ClipRRect(
            borderRadius: AppBorders.kBottom10,
            child: Assets.images.stockEntry.image(fit: BoxFit.cover),
          ),
          title: PageHeader(
            title: t.stockEntry.boxTitle(code: box.code),
            goBack: () => context.router.maybePop(),
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppInsets.all8,
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: AppInsets.left6,
                      child: Text(
                        t.stockEntry.currentCell(
                          address: state.cell?.address ?? '',
                        ),
                        style: SemiboldTextStyles().semiboldInter14.copyWith(
                          color: AppColors.kSidebarHover,
                        ),
                      ),
                    ),
                  ),
                  // У короба ЧЗ своя этикетка поставщика с SSCC — ярлык не нужен.
                  if (!box.isCz) ...[
                    AppBoxes.kWidth8,
                    BarIconButton(
                      onPressed: _printLabel,
                      icon: MdiIcons.printer,
                    ),
                  ],
                  if (state.undoStack.isNotEmpty) ...[
                    AppBoxes.kWidth8,
                    BarIconButton(onPressed: cubit.undo, icon: MdiIcons.undo),
                  ],
                  AppBoxes.kWidth8,
                  BarIconButton(
                    onPressed: _deleteBox,
                    icon: Icons.delete_outline,
                    color: AppColors.kDanger,
                  ),
                ],
              ),
            ),
            Padding(
              padding: AppInsets.h8,
              child: EntryScanField(
                controller: scanController,
                focusNode: scanFocus,
                onTap: addManual,
                onSubmitted: onScan,
              ),
            ),
            Expanded(
              child: lines.isEmpty
                  ? Center(child: Text(t.stockEntry.boxEmpty))
                  : ListView.builder(
                      padding: AppInsets.h8 + AppInsets.top8,
                      itemCount: lines.length,
                      itemBuilder: (context, i) => LineTile(
                        line: lines[i],
                        onLongPress: () => showLineMenu(lines[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
