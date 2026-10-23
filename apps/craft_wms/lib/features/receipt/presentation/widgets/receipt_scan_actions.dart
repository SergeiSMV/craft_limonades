import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../../core/constants/app_colors.dart';
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
import 'receipt_action_sheet.dart';
import 'receipt_cz_scan_actions.dart';
import 'receipt_label_actions.dart';

/// Скан и строки приёмки — общее для общего списка и страницы короба (ADHOC-18).
///
/// Что: поле скана, разбор кода, добавление строки (с привязкой ШК, «неверным товаром»,
/// выдачей внутреннего ШК), меню строки.
/// Зачем общий миксин: на обоих экранах товар принимают одинаково, а различаются они двумя
/// вещами — куда ложится строка ([scanBoxId]) и что значит скан ячейки и ярлыка короба.
/// Две копии этой логики разошлись бы на первой же правке — так уже было с резолвом ШК
/// в «Вводе остатков» (ADHOC-13).
///
/// Один скан-вход на всё: формы кодов не пересекаются (P4-04), поэтому кладовщику не нужно
/// переключать режимы — он сканирует то, что держит в руках.
mixin ReceiptScanActions<T extends StatefulWidget>
    on
        State<T>,
        HardwareScanListener<T>,
        ReceiptLabelActions<T>,
        ReceiptCzScanActions<T> {
  final scanController = TextEditingController();
  final scanFocus = FocusNode();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Короб, в который ложатся строки этого экрана; `null` — штучно (общий список).
  @override
  String? get scanBoxId;

  /// Отсканирован ярлык короба этой приёмки (или код короба ЧЗ, CZ-05).
  @override
  void onBoxScanned(String boxId);

  /// Отсканирована (или выбрана) ячейка.
  void onCellChosen(Cell cell);

  @override
  void dispose() {
    scanController.dispose();
    scanFocus.dispose();
    super.dispose();
  }

  ReceiptCubit get cubit => context.read<ReceiptCubit>();

  /// Вернуть фокус скан-полю (после диалогов) — иначе сканер DT50 печатает «в никуда».
  void refocusScan() {
    if (mounted) scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  //* --- скан --- *//

  /// Единая точка для обоих источников кода (поле и интент), поэтому отсечение дубля здесь:
  /// пара «поле + интент» иначе дала бы две строки прихода.
  Future<void> onScan(String value) async {
    final code = value.trim();
    scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) {
      refocusScan();
      return;
    }
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        _onBoxLabel(loadUnitIdFrom(code)!);
      case ScanKind.cell:
        await _onCellScan(code);
      case ScanKind.good:
        await _onGoodScan(code);
      // Марка и короб «Честного знака» читаются из ЧЗ (CZ-05).
      case ScanKind.czMark:
      case ScanKind.czBox:
        await onCzScan(code);
      case ScanKind.unknown:
        // Ярлык ГЕ новой версии — исправная этикетка, а не чужой код: «не распознан»
        // отправил бы кладовщика искать поломку, которой нет (P4-04).
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.receipt.boxLabelUnsupported);
        } else {
          await _onGoodScan(code);
        }
    }
    refocusScan();
  }

  /// Скан ярлыка короба: короб этой приёмки открывается, чужой — нет.
  void _onBoxLabel(String loadUnitId) {
    if (!cubit.hasBox(loadUnitId)) {
      snack(t.receipt.boxForeign);
      return;
    }
    onBoxScanned(loadUnitId.toLowerCase());
  }

  /// Скан этикетки ячейки. Адрес ищется в справочнике (кэш-first), а не принимается на веру —
  /// иначе опечатка в этикетке ушла бы в документ.
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
    onCellChosen(cell);
    snack(t.receipt.cell(address: cell.address));
  }

  /// Выбрать ячейку вручную — тот же лист, что во «Вводе остатков».
  Future<void> changeCell() async {
    final cell = await showModalBottomSheet<Cell>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.95,
      ),
      builder: (_) => CellChangeSheet(title: t.receipt.cellSheetTitle),
    );
    if (cell != null && mounted) onCellChosen(cell);
    refocusScan();
  }

  /// Скан штрихкода товара: опознан — строка; не привязан — выбор товара и привязка;
  /// проверить не удалось — спрашиваем, назвав причину (ADHOC-06).
  Future<void> _onGoodScan(String code) async {
    final resolved = await cubit.resolveBarcode(code);
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
    final picked = await pickGood();
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
    final picked = await pickGood();
    if (picked == null || !mounted) return;
    await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
  }

  //* --- строки --- *//

  /// Товар без штрихкода — выбор из номенклатуры. Если ШК у товара нет вовсе, предлагаем
  /// выдать внутренний и напечатать ярлык (P4-07, P4-08): иначе этот товар так и останется
  /// неопознаваемым сканом на следующих операциях.
  Future<void> addManual() async {
    if (inCzBox) {
      snack(t.receipt.czBoxClosed);
      refocusScan();
      return;
    }
    final picked = await pickGood();
    if (picked != null && mounted) {
      final codes = await cubit.barcodesOf(picked.id);
      if (!mounted) return;
      if (codes.isRight && codes.right.isEmpty) {
        await offerInternalBarcode(picked);
      }
      if (mounted) await _collectAndAdd(picked);
    }
    refocusScan();
  }

  /// Спросить дату и количество и добавить строку туда, куда кладёт этот экран.
  /// [scannedCode] включает «неверный товар»; [newBarcode] — ШК ещё не привязан и уйдёт
  /// привязкой в очередь.
  Future<void> _collectAndAdd(
    Good good, {
    String? scannedCode,
    String? newBarcode,
  }) async {
    // Маркируемый товар принимается только марками (долг 16), в короб ЧЗ не добавляют ничего.
    if (inCzBox) {
      snack(t.receipt.czBoxClosed);
      return;
    }
    if (good.czMarked) {
      snack(t.receipt.czScanMark);
      return;
    }
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
    await cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
      boxId: scanBoxId,
    );
  }

  /// «Неверный товар»: снять ошибочную привязку и предложить правильный товар.
  Future<void> _handleWrongGood(String code, {required String goodId}) async {
    await cubit.removeBarcode(code, goodId: goodId);
    if (!mounted) return;
    snack(t.receipt.barcodeUnbound);
    final picked = await pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
    }
  }

  /// Меню строки по долгому нажатию.
  ///
  /// Строку с марками ЧЗ не правят: количество — число марок, партия — из ЧЗ (CZ-05). Строку
  /// короба ЧЗ и не удаляют: короб уходит только целиком, с его страницы.
  Future<void> showLineMenu(ReceiptLineDraft line) async {
    final czBox =
        line.boxId != null && (cubit.state.boxById(line.boxId!)?.isCz ?? false);
    final action = await showReceiptActionSheet<String>(context, [
      if (line.marks.isEmpty)
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
      if (!czBox)
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
        cubit.removeLine(line);
    }
    refocusScan();
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
    cubit.editLine(line, date: res.date, qty: res.qty);
  }

  /// Нижний лист выбора товара из номенклатуры.
  @override
  Future<Good?> pickGood() => showModalBottomSheet<Good>(
    backgroundColor: AppColors.kNeumorphicBg,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.95,
    ),
    builder: (_) => GoodPickerSheet(repo: getIt<CatalogRepository>()),
  );
}
