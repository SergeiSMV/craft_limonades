import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

import '../../../../core/constants/app_boxes.dart';
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
import '../../../../core/widgets/date_qty_dialog.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../cz/domain/cz_intake.dart';
import '../../../cz/domain/cz_intake_hold.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../cz/presentation/widgets/cz_intake_scan.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/entry_models.dart';
import '../bloc/stock_entry_cubit.dart';

/// Скан и строки «Ввода остатков» - общее для ячейки и короба прохода (ADHOC-46).
///
/// Что: поле скана, разбор кода, добавление строки (с привязкой ШК и «неверным товаром»),
/// короба (ярлык своего короба, короб ЧЗ одним сканом SSCC), марки ЧЗ, меню строки.
/// Зачем общий миксин: в ячейке и в коробе товар вводят одинаково, а различаются они двумя
/// вещами - куда ложится строка ([scanBoxId]) и что значит скан ярлыка короба. Тот же приём,
/// что у приёмки (ADHOC-18).
///
/// Один скан-вход на всё: формы кодов не пересекаются (P4-04), режимы переключать не нужно.
mixin EntryScanActions<T extends StatefulWidget>
    on State<T>, HardwareScanListener<T>, CzIntakeScan<T> {
  final scanController = TextEditingController();
  final scanFocus = FocusNode();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Отсканирован короб текущей ячейки - экран решает, открыть ли его.
  void onBoxScanned(String boxId);

  @override
  void dispose() {
    scanController.dispose();
    scanFocus.dispose();
    super.dispose();
  }

  StockEntryCubit get cubit => context.read<StockEntryCubit>();

  /// Короб экрана - закрытый короб ЧЗ: в него ничего не добавляют.
  bool get inCzBox {
    final id = scanBoxId;
    return id != null && (cubit.state.boxById(id)?.isCz ?? false);
  }

  /// Вернуть фокус скан-полю (после диалогов) - иначе сканер DT50 печатает «в никуда».
  void refocusScan() {
    if (mounted) scanFocus.requestFocus();
  }

  /// Показать снекбар с текстом (сообщения потока ввода).
  @override
  void snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Код с аппаратного сканера (intent-режим) - тот же путь, что у ввода в поле.
  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  //* --- скан --- *//

  /// Единая точка для обоих источников кода (поле и интент), поэтому отсечение дубля здесь:
  /// пара «поле + интент» иначе дала бы две строки остатка.
  Future<void> onScan(String value) async {
    final code = value.trim();
    scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) {
      refocusScan();
      return;
    }
    final kind = classifyScan(code);
    // Марка и короб ЧЗ встают в очередь чтения и ответа не ждут (ADHOC-70).
    if (kind == ScanKind.czMark || kind == ScanKind.czBox) {
      _onCzScan(code);
      refocusScan();
      return;
    }
    // Остальные сканы - после марок, отсканированных раньше: короб, открытый до ответа ЧЗ,
    // увёл бы в себя марки, отсканированные россыпью.
    if (!await czSettle()) return;
    switch (kind) {
      case ScanKind.cargoUnit:
        _onBoxLabel(loadUnitIdFrom(code)!);
      case ScanKind.czMark:
      case ScanKind.czBox:
        break;
      case ScanKind.cell:
        // Код ячейки в поле товара: ручной выбор товара НЕ открываем - иначе адрес ячейки
        // привязался бы к выбранному товару как штрихкод.
        snack(t.stockEntry.scannedCellInGood);
      case ScanKind.good:
        await _onGoodScan(code);
      case ScanKind.unknown:
        // Ярлык ГЕ новой версии - исправная этикетка, а не чужой код (P4-04).
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.stockEntry.boxLabelUnsupported);
        } else {
          await _onGoodScan(code);
        }
    }
    refocusScan();
  }

  /// Скан ярлыка короба: короб текущей ячейки открывается. Короб не отсюда - либо заведён в
  /// другой ячейке прохода, либо уже на складе: уже размещённый короб проход не пересчитывает.
  void _onBoxLabel(String loadUnitId) {
    if (cubit.hasBox(loadUnitId)) {
      onBoxScanned(loadUnitId.toLowerCase());
    } else if (cubit.boxInOtherCell(loadUnitId)) {
      snack(t.stockEntry.boxOtherCell);
    } else {
      snack(t.stockEntry.boxForeign);
    }
  }

  /// Короб ЧЗ, уже отсканированный в этой ячейке, открывается; в другой ячейке прохода - нет.
  @override
  bool openOwnCzBox(String code) {
    final id = cubit.czBoxIdByCode(code);
    if (id != null) {
      onBoxScanned(id);
      return true;
    }
    if (cubit.state.passBoxes.any((b) => b.czCode == code)) {
      snack(t.stockEntry.boxOtherCell);
      return true;
    }
    return false;
  }

  /// Скан кода ЧЗ: в закрытый короб ЧЗ - отказ, иначе в очередь чтения (ADHOC-70).
  void _onCzScan(String code) {
    if (inCzBox) {
      snack(t.stockEntry.czBoxClosed);
      return;
    }
    czEnqueue(code);
  }

  /// Марка или упаковка уже в проходе - повтор не читается.
  @override
  bool czAlreadyHere(String key) =>
      cubit.state.passLines.any((l) => l.marks.any((m) => m.cis == key)) ||
      cubit.state.passGroups.any((g) => g.code == key);

  @override
  CzIntakeHold get czHold => cubit.czHold;

  @override
  CzIntakeTexts get czTexts => CzIntakeTexts(
    marksAdded: (n) => t.stockEntry.czMarksAdded(count: n),
    boxAdded: (n) => t.stockEntry.czBoxAdded(count: n),
    duplicate: t.stockEntry.czDuplicate,
    boxClosed: t.stockEntry.czBoxClosed,
    unreadable: (n) => t.stockEntry.czUnreadable(count: n),
    discrepancy: t.stockEntry.czDiscrepancyAdded,
  );

  /// Положить прочитанное: короб ЧЗ - новой ГЕ ячейки, марки - в короб скана или россыпью.
  @override
  CzIntakeAdd czApply(CzIntakeRead read, {String? boxId}) {
    if (read.scan.kind == CzCodeKind.box) {
      return cubit
          .addCzBox(
            code: read.scan.code,
            lines: read.lines,
            groups: read.groups,
          )
          .result;
    }
    return cubit.addCzMarks(
      lines: read.lines,
      groups: read.groups,
      boxId: boxId,
    );
  }

  /// Скан ШК товара. Резолв кэш-first; не привязан - выбор товара и привязка очередью;
  /// проверить не удалось - спрашиваем, назвав причину (ADHOC-06).
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
    snack(t.stockEntry.goodNotBound);
    final picked = await pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
    }
  }

  /// Привязать ШК, который не удалось проверить: решение за кладовщиком, он видит упаковку.
  /// Если код занят другим товаром, сервер отклонит привязку и она попадёт на экран разбора -
  /// строка остатка от этого не страдает, товар выбран руками.
  Future<void> _bindUnverified(String code, Failure failure) async {
    final reason = failure is NetworkFailure
        ? t.stockEntry.barcodeOffline(barcode: code)
        : t.stockEntry.barcodeLookupFailed(barcode: code);
    final confirmed = await showBindPromptDialog(
      context,
      title: t.stockEntry.bindOfflineTitle,
      body: reason,
      confirmLabel: t.stockEntry.bindOfflineConfirm,
      cancelLabel: t.stockEntry.bindOfflineCancel,
    );
    if (!confirmed || !mounted) return;
    final picked = await pickGood();
    if (picked == null || !mounted) return;
    await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
  }

  //* --- строки --- *//

  /// Ручное добавление товара (без ШК) - кнопки «неверный товар» тут нет (нет ШК).
  Future<void> addManual() async {
    if (inCzBox) {
      snack(t.stockEntry.czBoxClosed);
    } else {
      final picked = await pickGood();
      if (picked != null && mounted) await _collectAndAdd(picked);
    }
    refocusScan();
  }

  /// Спросить дату и количество и добавить строку туда, куда кладёт этот экран.
  /// [scannedCode] включает «неверный товар»; [newBarcode] - ШК ещё не привязан и уйдёт
  /// привязкой в очередь.
  ///
  /// Маркируемый товар вводится только марками (ADHOC-46), в короб ЧЗ не добавляют ничего.
  Future<void> _collectAndAdd(
    Good good, {
    String? scannedCode,
    String? newBarcode,
  }) async {
    if (inCzBox) {
      snack(t.stockEntry.czBoxClosed);
      return;
    }
    if (good.czMarked) {
      snack(t.stockEntry.czScanMark);
      return;
    }
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) =>
          DateQtyDialog(good: good, allowWrongGood: scannedCode != null),
    );
    if (res == null || !mounted) return;
    if (res.wrongGood) {
      // allowWrongGood истинен только при непустом scannedCode
      await _handleWrongGood(scannedCode!, goodId: good.id);
      return;
    }
    await cubit.addLine(
      good: good,
      date: res.date,
      qty: res.qty,
      newBarcode: newBarcode,
      symbology: newBarcode != null ? '' : null,
      boxId: scanBoxId,
    );
  }

  /// «Неверный товар»: снять ошибочную привязку ШК и предложить правильный товар.
  ///
  /// Что именно делать, решает cubit: неушедшую привязку он снимает из очереди, ушедшую -
  /// отвязывает. Обе ветки идут через очередь и переживают отсутствие связи (ADHOC-14).
  Future<void> _handleWrongGood(String code, {required String goodId}) async {
    await cubit.removeBarcode(code, goodId: goodId);
    if (!mounted) return;
    snack(t.stockEntry.barcodeUnbound);
    final picked = await pickGood();
    if (picked != null && mounted) {
      await _collectAndAdd(picked, scannedCode: code, newBarcode: code);
    }
  }

  /// Меню по долгому нажатию на строку: редактировать / удалить.
  ///
  /// Строку с марками ЧЗ не правят: количество - число марок, партия - из ЧЗ. Строку короба ЧЗ
  /// и не удаляют: короб уходит только целиком, со своей страницы.
  Future<void> showLineMenu(EntryLineDraft line) async {
    final czBox =
        line.boxId != null && (cubit.state.boxById(line.boxId!)?.isCz ?? false);
    final canEdit = line.marks.isEmpty;
    if (!canEdit && czBox) return;
    final action = await showModalBottomSheet<String>(
      backgroundColor: AppColors.kNeumorphicBg,
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: AppInsets.all16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canEdit)
                NeumorphicButton(
                  onPressed: () => Navigator.of(context).pop('edit'),
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(t.stockEntry.edit),
                  ),
                ),
              if (canEdit && !czBox) AppBoxes.kHeight8,
              if (!czBox)
                NeumorphicButton(
                  onPressed: () => Navigator.of(context).pop('delete'),
                  style: NeumorphicStyle(
                    shadowLightColor: AppColors.kNeumorphicLight,
                    shadowDarkColor: AppColors.kNeumorphicDark,
                    intensity: 1,
                    color: AppColors.kNeumorphicBg,
                    depth: 3,
                    shape: NeumorphicShape.flat,
                  ),
                  child: ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: AppColors.kDanger,
                    ),
                    title: Text(
                      t.stockEntry.delete,
                      style: const TextStyle(color: AppColors.kDanger),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      cubit.removeLine(line);
    } else if (action == 'edit') {
      await _editLine(line);
    }
    refocusScan();
  }

  /// Редактирование строки: диалог с текущими датой и количеством (без «неверного товара» -
  /// правка уже добавленной строки не про привязку ШК).
  Future<void> _editLine(EntryLineDraft line) async {
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

  /// Нижний лист выбора товара из номенклатуры; возвращает выбранный товар или `null`.
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
