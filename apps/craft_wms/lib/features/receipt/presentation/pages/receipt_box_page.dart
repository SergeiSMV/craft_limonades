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
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/widgets/page_header.dart';
import '../../../../core/widgets/system_ui_wrapper.dart';
import '../../../stock/data/catalog_models.dart';
import '../bloc/receipt_cubit.dart';
import '../widgets/receipt_context_bar.dart';
import '../widgets/receipt_label_actions.dart';
import '../widgets/receipt_line_tile.dart';
import '../widgets/receipt_scan_actions.dart';
import '../widgets/receipt_scan_field.dart';

/// Страница короба приёмки (ADHOC-18): только содержимое этого короба.
///
/// Здесь сканы ложатся в короб, отсюда печатают его ярлык, меняют его ячейку (короб переезжает
/// целиком), удаляют позиции и сам короб. Отдельная страница, а не переключатель «текущий
/// короб» в общем списке: переключатель легко забыть, и товар молча уезжал бы не в тот короб.
///
/// Cubit приходит от общего списка: короб — часть той же приёмки, и правки здесь сразу
/// ложатся в её черновик.
@RoutePage()
class ReceiptBoxPage extends StatelessWidget {
  const ReceiptBoxPage({super.key, required this.cubit, required this.boxId});

  final ReceiptCubit cubit;
  final String boxId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: cubit,
      child: _ReceiptBoxView(boxId: boxId),
    );
  }
}

class _ReceiptBoxView extends StatefulWidget {
  const _ReceiptBoxView({required this.boxId});

  final String boxId;

  @override
  State<_ReceiptBoxView> createState() => _ReceiptBoxViewState();
}

class _ReceiptBoxViewState extends State<_ReceiptBoxView>
    with
        HardwareScanListener,
        ReceiptLabelActions,
        ReceiptScanActions<_ReceiptBoxView> {
  /// Строки этой страницы ложатся в короб.
  @override
  String? get scanBoxId => widget.boxId;

  /// Ярлык другого короба этой приёмки — переходим в него, не возвращаясь в общий список:
  /// так раскладывают товар по нескольким коробам подряд.
  @override
  void onBoxScanned(String boxId) {
    if (boxId == widget.boxId) {
      snack(t.receipt.boxAlreadyOpen);
      return;
    }
    context.router.replace(ReceiptBoxRoute(cubit: cubit, boxId: boxId));
  }

  /// Ячейка на странице короба переносит короб целиком (решение пользователя, ADHOC-18).
  @override
  void onCellChosen(Cell cell) => cubit.setBoxCell(widget.boxId, cell);

  /// Удалить короб с позициями — после подтверждения: ярлык уже мог быть напечатан.
  Future<void> _deleteBox() async {
    final ok = await showBindPromptDialog(
      context,
      title: t.receipt.boxDeleteTitle,
      body: t.receipt.boxDeleteBody(
        count: cubit.state.linesInBox(widget.boxId),
      ),
      confirmLabel: t.receipt.boxDeleteConfirm,
      cancelLabel: t.receipt.cancel,
    );
    if (!ok || !mounted) return;
    cubit.removeBox(widget.boxId);
    context.router.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReceiptCubit>().state;
    final box = state.boxById(widget.boxId);
    // Короб удалён — страница уже закрывается, рисовать нечего.
    if (box == null) return const SizedBox.shrink();
    final lines = state
        .linesOf(box.id)
        .reversed
        .toList(); // свежая строка — сверху
    final cellText = box.cell == null
        ? t.receipt.cellDefault(address: state.defaultCell?.address ?? '')
        : t.receipt.cell(address: box.cell!.address);
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
            child: Assets.images.featuredSnacks.image(fit: BoxFit.cover),
          ),
          title: PageHeader(
            title: t.receipt.box(code: box.shortCode),
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
                    child: ReceiptBarButton(
                      onPressed: changeCell,
                      text: cellText,
                      icon: MdiIcons.cogTransfer,
                    ),
                  ),
                  AppBoxes.kWidth8,
                  ReceiptIconButton(
                    onPressed: () => printBoxLabel(box.id),
                    icon: MdiIcons.printer,
                  ),
                  AppBoxes.kWidth8,
                  ReceiptIconButton(
                    onPressed: _deleteBox,
                    icon: Icons.delete_outline,
                    color: AppColors.kDanger,
                  ),
                ],
              ),
            ),
            Padding(
              padding: AppInsets.h8,
              child: ReceiptScanField(
                controller: scanController,
                focusNode: scanFocus,
                onTap: addManual,
                onSubmitted: onScan,
              ),
            ),
            Expanded(
              child: lines.isEmpty
                  ? Center(child: Text(t.receipt.boxEmpty))
                  : ListView.builder(
                      padding: AppInsets.h8 + AppInsets.top8,
                      itemCount: lines.length,
                      itemBuilder: (context, i) => ReceiptLineTile(
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
