import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_insets.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/widgets/cell_change_sheet.dart';
import '../../../../core/widgets/date_qty_dialog.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../bloc/receipt_cubit.dart';
import '../bloc/receipt_models.dart';
import 'box_picker_sheet.dart';
import 'receipt_action_sheet.dart';
import 'receipt_context_bar.dart';
import 'receipt_label_actions.dart';
import 'receipt_line_tile.dart';
import 'receipt_scan_field.dart';

/// Рабочий экран приёмки: шапка контекста, поле скана, строки, «Завершить приёмку».
///
/// Один скан-вход на всё: ярлык короба делает короб текущим, этикетка ячейки меняет ячейку,
/// штрихкод товара добавляет строку. Формы кодов не пересекаются (P4-04), поэтому кладовщику
/// не нужно переключать режимы — он сканирует то, что держит в руках.
class ReceiptWorkView extends StatefulWidget {
  const ReceiptWorkView({super.key, required this.state});

  final ReceiptState state;

  @override
  State<ReceiptWorkView> createState() => _ReceiptWorkViewState();
}

class _ReceiptWorkViewState extends State<ReceiptWorkView>
    with HardwareScanListener, ReceiptLabelActions {
  final _scanController = TextEditingController();
  final _scanFocus = FocusNode();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  ReceiptCubit get _cubit => context.read<ReceiptCubit>();

  /// Вернуть фокус скан-полю (после диалогов) — иначе сканер DT50 печатает «в никуда».
  void _refocusScan() {
    if (mounted) _scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => _onScan(code.raw);

  //* --- скан --- *//

  /// Единая точка для обоих источников кода (поле и интент), поэтому отсечение дубля здесь:
  /// пара «поле + интент» иначе дала бы две строки прихода.
  Future<void> _onScan(String value) async {
    final code = value.trim();
    _scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) {
      _refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        _onBoxScan(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await _onCellScan(code);
      case ScanKind.good:
        await _onGoodScan(code);
      case ScanKind.unknown:
        // Ярлык ГЕ новой версии — исправная этикетка, а не чужой код: «не распознан»
        // отправил бы кладовщика искать поломку, которой нет (P4-04).
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.receipt.boxLabelUnsupported);
        } else {
          await _onGoodScan(code);
        }
    }
    _refocusScan();
  }

  /// Скан ярлыка короба: короб этой приёмки становится текущим.
  void _onBoxScan(String loadUnitId) {
    if (!_cubit.selectScannedBox(loadUnitId)) {
      snack(t.receipt.boxForeign);
      return;
    }
    snack(t.receipt.boxSelected(code: _cubit.state.currentBox!.shortCode));
  }

  /// Скан этикетки ячейки: дальше товар ложится туда. Адрес ищется в справочнике (кэш-first),
  /// а не принимается на веру — иначе опечатка в этикетке ушла бы в документ.
  Future<void> _onCellScan(String address) async {
    final res = await getIt<CatalogRepository>().listAllCells();
    if (!mounted) return;
    final a = address.toLowerCase();
    final cell = res
        .fold((_) => const <Cell>[], (cells) => cells)
        .where((c) => c.address.toLowerCase() == a)
        .firstOrNull;
    if (cell == null) {
      snack(t.receipt.cellNotFound(address: address));
      return;
    }
    _cubit.setTargetCell(cell);
    snack(t.receipt.cell(address: cell.address));
  }

  /// Скан штрихкода товара: опознан — строка; не привязан — выбор товара и привязка;
  /// проверить не удалось — спрашиваем, назвав причину (ADHOC-06).
  Future<void> _onGoodScan(String code) async {
    final resolved = await _cubit.resolveBarcode(code);
    if (!mounted) return;
    if (resolved.isLeft) {
      await _bindUnverified(code, resolved.left);
      return;
    }
    final good = resolved.right;
    if (good != null) {
      await _collectAndAdd(good, scannedCode: code);
      return;
    }
    snack(t.receipt.goodNotBound);
    final picked = await _pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
    }
  }

  /// Привязать ШК, который не удалось проверить: решение за кладовщиком, он видит упаковку.
  /// Если код занят другим товаром, сервер отклонит привязку и она попадёт на экран разбора —
  /// строка прихода от этого не страдает, товар выбран руками.
  Future<void> _bindUnverified(String code, Failure failure) async {
    final confirmed = await showBindPromptDialog(
      context,
      title: t.receipt.bindOfflineTitle,
      body: failure is NetworkFailure
          ? t.receipt.barcodeOffline(barcode: code)
          : t.receipt.barcodeLookupFailed(barcode: code),
      confirmLabel: t.receipt.bindOfflineConfirm,
      cancelLabel: t.receipt.cancel,
    );
    if (!confirmed || !mounted) return;
    final picked = await _pickGood();
    if (picked == null || !mounted) return;
    await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
  }

  //* --- строки --- *//

  /// Товар без штрихкода — выбор из номенклатуры. Если ШК у товара нет вовсе, предлагаем
  /// выдать внутренний и напечатать ярлык (P4-07, P4-08): иначе этот товар так и останется
  /// неопознаваемым сканом на следующих операциях.
  Future<void> _addManual() async {
    final picked = await _pickGood();
    if (picked != null && mounted) {
      final codes = await _cubit.barcodesOf(picked.id);
      if (!mounted) return;
      if (codes.isRight && codes.right.isEmpty) {
        await offerInternalBarcode(picked);
      }
      if (mounted) await _collectAndAdd(picked);
    }
    _refocusScan();
  }

  /// Спросить дату и количество и добавить строку. [scannedCode] включает «неверный товар»;
  /// [newBarcode] — ШК ещё не привязан и уйдёт привязкой в очередь.
  Future<void> _collectAndAdd(
    Good good, {
    String? scannedCode,
    String? newBarcode,
  }) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) =>
          DateQtyDialog(good: good, allowWrongGood: scannedCode != null),
    );
    if (res == null || !mounted) return;
    if (res.wrongGood) {
      await _handleWrongGood(scannedCode!, goodId: good.id);
      return;
    }
    await _cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
    );
  }

  /// «Неверный товар»: снять ошибочную привязку и предложить правильный товар.
  Future<void> _handleWrongGood(String code, {required String goodId}) async {
    await _cubit.removeBarcode(code, goodId: goodId);
    if (!mounted) return;
    snack(t.receipt.barcodeUnbound);
    final picked = await _pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
    }
  }

  /// Меню строки по долгому нажатию.
  Future<void> _showLineMenu(ReceiptLineDraft line) async {
    final action = await showReceiptActionSheet<String>(context, [
      ReceiptAction(
        value: 'edit',
        icon: Icons.edit_outlined,
        label: t.receipt.edit,
      ),
      ReceiptAction(
        value: 'print',
        icon: MdiIcons.printer,
        label: t.receipt.printGoodLabel,
      ),
      ReceiptAction(
        value: 'delete',
        icon: Icons.delete_outline,
        label: t.receipt.delete,
        danger: true,
      ),
    ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        await _editLine(line);
      case 'print':
        await printGoodLabel(line.good);
      case 'delete':
        _cubit.removeLine(line);
    }
    _refocusScan();
  }

  /// Правка даты и количества строки.
  Future<void> _editLine(ReceiptLineDraft line) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) => DateQtyDialog(
        good: line.good,
        initialDate: line.productionDate,
        initialQty: line.qty,
      ),
    );
    if (res == null || res.wrongGood || !mounted) return;
    _cubit.editLine(line, date: res.date, qty: res.qty);
  }

  /// Нижний лист выбора товара из номенклатуры.
  Future<Good?> _pickGood() => showModalBottomSheet<Good>(
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.95,
    ),
    builder: (_) => GoodPickerSheet(repo: getIt<CatalogRepository>()),
  );

  //* --- ячейка и короба --- *//

  /// Сменить ячейку вручную — тот же лист, что во «Вводе остатков».
  Future<void> _changeCell() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      builder: (_) => CellChangeSheet(title: t.receipt.cellSheetTitle),
    );
    if (cell != null && mounted) _cubit.setTargetCell(cell);
    _refocusScan();
  }

  /// Новый короб: заводим и сразу печатаем ярлык — его клеят на короб до того, как класть.
  Future<void> _newBox() async {
    await printBoxLabel(_cubit.newBox());
    _refocusScan();
  }

  /// Выбрать короб из списка приёмки — когда ярлык не читается.
  Future<void> _pickBox() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BoxPickerSheet(cubit: _cubit, cellOf: _boxCellAddress),
    );
    if (id != null && mounted) _cubit.selectBox(id);
    _refocusScan();
  }

  /// Действия с текущим коробом.
  Future<void> _boxMenu() async {
    final box = _cubit.state.currentBox;
    if (box == null) return;
    final action = await showReceiptActionSheet<String>(context, [
      ReceiptAction(
        value: 'print',
        icon: MdiIcons.printer,
        label: t.receipt.reprintBox,
      ),
      ReceiptAction(
        value: 'close',
        icon: MdiIcons.packageVariant,
        label: t.receipt.closeBox,
      ),
    ]);
    if (!mounted || action == null) return;
    if (action == 'print') await printBoxLabel(box.id);
    if (action == 'close') _cubit.closeBox();
    _refocusScan();
  }

  /// Адрес ячейки короба — для подписи в списке коробов.
  String _boxCellAddress(ReceiptBox box) =>
      box.cell?.address ?? widget.state.defaultCell?.address ?? '';

  //* --- завершение --- *//

  /// Подтвердить и отправить: после отправки приёмку не изменить, поэтому спрашиваем.
  Future<void> _submit() async {
    final ok = await showBindPromptDialog(
      context,
      title: t.receipt.submitTitle,
      body: t.receipt.submitBody(count: widget.state.lines.length),
      confirmLabel: t.receipt.submitConfirm,
      cancelLabel: t.receipt.cancel,
    );
    if (ok && mounted) await _cubit.submit();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReceiptContextBar(
          state: state,
          onChangeCell: _changeCell,
          onNewBox: _newBox,
          onPickBox: _pickBox,
          onBoxMenu: _boxMenu,
        ),
        Padding(
          padding: AppInsets.h8,
          child: ReceiptScanField(
            controller: _scanController,
            focusNode: _scanFocus,
            onTap: _addManual,
            onSubmitted: _onScan,
          ),
        ),
        Expanded(
          child: state.lines.isEmpty
              ? const ReceiptEmptyHint()
              : ListView.builder(
                  padding: AppInsets.h8 + AppInsets.top8,
                  itemCount: state.lines.length,
                  // Свежая строка — сверху.
                  itemBuilder: (context, i) {
                    final line = state.lines[state.lines.length - 1 - i];
                    final box = state.boxes
                        .where((b) => b.id == line.boxId)
                        .firstOrNull;
                    return ReceiptLineTile(
                      line: line,
                      boxCode: box?.shortCode,
                      cellAddress:
                          line.cell?.address ??
                          state.defaultCell?.address ??
                          '',
                      onLongPress: () => _showLineMenu(line),
                    );
                  },
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
