import 'package:auto_route/auto_route.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_insets.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../stock/data/catalog_models.dart';
import '../bloc/receipt_cubit.dart';
import 'receipt_box_tile.dart';
import 'receipt_context_bar.dart';
import 'receipt_label_actions.dart';
import 'receipt_line_tile.dart';
import 'receipt_scan_actions.dart';
import 'receipt_scan_field.dart';

/// Общий список приёмки: шапка (поставщик, ячейка, «новый короб»), поле скана, короба
/// и штучные строки, «Завершить приёмку».
///
/// Здесь товар принимается штучно. В короб кладут на его странице (ADHOC-18): там видно только
/// содержимое короба, и строка не уйдёт в «не тот» короб из-за забытого переключателя.
class ReceiptWorkView extends StatefulWidget {
  const ReceiptWorkView({super.key, required this.state});

  final ReceiptState state;

  @override
  State<ReceiptWorkView> createState() => _ReceiptWorkViewState();
}

class _ReceiptWorkViewState extends State<ReceiptWorkView>
    with
        HardwareScanListener,
        ReceiptLabelActions,
        ReceiptScanActions<ReceiptWorkView> {
  /// В общем списке строки ложатся штучно.
  @override
  String? get scanBoxId => null;

  /// Скан ярлыка короба открывает его страницу.
  @override
  void onBoxScanned(String boxId) => _openBox(boxId);

  /// Ячейка в общем списке — для штучных строк и новых коробов.
  @override
  void onCellChosen(Cell cell) => cubit.setTargetCell(cell);

  /// Открыть страницу короба. Cubit передаётся тот же: короб — часть этой приёмки, и его
  /// страница правит то же состояние и тот же черновик.
  Future<void> _openBox(String boxId) async {
    await context.router.push(ReceiptBoxRoute(cubit: cubit, boxId: boxId));
    refocusScan();
  }

  /// Новый короб: заводим и сразу открываем — следующие сканы пойдут в него. Ярлык кладовщик
  /// печатает сам со страницы короба (решение пользователя, ADHOC-18).
  Future<void> _newBox() => _openBox(cubit.newBox());

  /// Подтвердить и отправить: после отправки приёмку не изменить, поэтому спрашиваем.
  Future<void> _submit() async {
    final ok = await showBindPromptDialog(
      context,
      title: t.receipt.submitTitle,
      body: t.receipt.submitBody(count: widget.state.lines.length),
      confirmLabel: t.receipt.submitConfirm,
      cancelLabel: t.receipt.cancel,
    );
    if (ok && mounted) await cubit.submit();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final loose = state.looseLines.reversed.toList(); // свежая строка — сверху
    final boxes = state.boxes.reversed.toList(); // свежий короб — сверху
    final defaultAddress = state.defaultCell?.address ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReceiptContextBar(
          state: state,
          onChangeCell: changeCell,
          onNewBox: _newBox,
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
          child: boxes.isEmpty && loose.isEmpty
              ? const ReceiptEmptyHint()
              : ListView(
                  padding: AppInsets.h8 + AppInsets.top8,
                  children: [
                    // Короба сверху: их немного, и в них проваливаются; штучные строки — ниже.
                    for (final b in boxes)
                      ReceiptBoxTile(
                        box: b,
                        positions: state.linesInBox(b.id),
                        cellAddress: b.cell?.address ?? defaultAddress,
                        onTap: () => _openBox(b.id),
                      ),
                    for (final line in loose)
                      ReceiptLineTile(
                        line: line,
                        cellAddress: line.cell?.address ?? defaultAddress,
                        onLongPress: () => showLineMenu(line),
                      ),
                  ],
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: AppInsets.all16,
            child: FilledButton.icon(
              onPressed: state.canSubmit ? _submit : null,
              icon: const Icon(Icons.check),
              label: Text(t.receipt.submit),
            ),
          ),
        ),
      ],
    );
  }
}
