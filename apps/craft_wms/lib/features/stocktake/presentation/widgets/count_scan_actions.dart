import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/scanner/scan_serial.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/widgets/bind_prompt_dialog.dart';
import '../../../../core/widgets/date_qty_dialog.dart';
import '../../../../core/widgets/good_picker_sheet.dart';
import '../../../../core/warehouse/internal_warehouses.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../cz/domain/cz_scan.dart';
import '../../../cz/domain/cz_stock_marks.dart';
import '../../../stock/data/catalog_models.dart';
import '../../../stock/data/catalog_repository.dart';
import '../../domain/stocktake_count.dart';
import '../../domain/stocktake_models.dart';
import '../bloc/stocktake_count_cubit.dart';
import 'position_pick_sheet.dart';

/// Скан при подсчёте ячейки пересчёта (P10-04).
///
/// Что: разбор кода — ярлык короба, этикетка короба ЧЗ, марка, штрихкод товара — и что из него
/// насчитать. Россыпь без марок — как во «Вводе остатков»: товар по ШК, дата и количество в
/// диалоге (партия подставлена из снимка), насчитанное копится к позиции.
/// Зачем отдельно от экрана: у экрана и так список, кнопки и итог; правила «что за код» живут
/// здесь и опираются на справочники терминала — подсчёт идёт без связи.
/// Как: короб и марку терминал узнаёт по своему снимку склада. Неизвестный WMS короб или марку
/// не отмечаем — сервер всё равно отклонит весь подсчёт, а кладовщик узнал бы об этом позже.
mixin CountScanActions<T extends StatefulWidget>
    on State<T>, HardwareScanListener<T> {
  final scanController = TextEditingController();
  final scanFocus = FocusNode();
  final _deduper = ScanDeduper();

  StocktakeCountCubit get cubit => context.read<StocktakeCountCubit>();
  StocktakeCount get count => cubit.state.count;
  ContentsRepository get _contents => getIt<ContentsRepository>();
  CatalogRepository get _catalog => getIt<CatalogRepository>();

  /// Показать снекбар с текстом.
  void snack(String text);

  @override
  void dispose() {
    scanController.dispose();
    scanFocus.dispose();
    super.dispose();
  }

  /// Вернуть фокус полю скана — иначе сканер DT50 печатает «в никуда».
  void refocusScan() {
    if (mounted) scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Сканы экрана — по одному, в порядке прихода (ADHOC-70).
  final _scans = ScanSerial('Пересчёт');

  /// Единая точка для поля и интента сканера.
  Future<void> onScan(String value) async {
    final code = value.trim();
    scanController.clear();
    if (code.isEmpty || !_deduper.allow(code) || cubit.state.outcome != null) {
      refocusScan();
      return;
    }
    await _scans.run(() => _handleScan(code));
  }

  /// Обработать один скан: уже в очереди сканов экрана.
  Future<void> _handleScan(String code) async {
    if (!mounted) return;
    switch (classifyScan(code)) {
      case ScanKind.cargoUnit:
        await _onBox(loadUnitIdFrom(code)!);
      case ScanKind.czBox:
        await _onCzBox(czBoxFrom(code)!);
      case ScanKind.czMark:
        await _onMark(czMarkFrom(code)!);
      case ScanKind.cell:
        snack(t.stocktake.scannedCell);
      case ScanKind.good:
        await _onGood(code);
      case ScanKind.unknown:
        if (readLoadUnitPayload(code) is LoadUnitPayloadUnsupported) {
          snack(t.stocktake.boxLabelUnsupported);
        } else {
          await _onGood(code);
        }
    }
    refocusScan();
  }

  /// Ярлык короба: короб снимка — найден; другой — только если WMS его знает.
  Future<void> _onBox(String id) async {
    final inSnapshot = count.boxPositions.any(
      (p) => p.loadUnitId!.toLowerCase() == id.toLowerCase(),
    );
    if (!inSnapshot) {
      final res = await _contents.loadUnit(id);
      if (!mounted) return;
      if (res.isLeft || res.right.value == null) {
        snack(t.stocktake.boxUnknown);
        return;
      }
    }
    cubit.foundBox(id);
  }

  /// Этикетка короба ЧЗ (`00`+SSCC): ярлыка WMS у такого короба нет.
  Future<void> _onCzBox(String czCode) async {
    final own = count.boxPositions.where((p) => p.czCode == czCode).firstOrNull;
    if (own != null) {
      cubit.foundBox(own.loadUnitId!, czCode: czCode);
      return;
    }
    final res = await _contents.loadUnitIdByCzCode(czCode);
    if (!mounted) return;
    final id = res.isRight ? res.right : null;
    if (id == null) {
      snack(t.stocktake.boxUnknown);
      return;
    }
    cubit.foundBox(id, czCode: czCode);
  }

  /// Марка или групповая упаковка ЧЗ: товар и партия — из снимка склада терминала.
  ///
  /// Склад позиции: марка лежит здесь россыпью — её склад; лежит в другом месте — склад
  /// позиции снимка того же товара и партии, иначе «Основной».
  Future<void> _onMark(String code) async {
    final found = await stockMarksByCode(
      code,
      contents: _contents,
      cz: getIt<CzScanRepository>(),
      defaultWarehouseId: getIt<InternalWarehouses>().defaultId,
    );
    if (!mounted) return;
    if (found.isEmpty) {
      snack(t.stocktake.markUnknown);
      return;
    }
    final first = found.first;
    final good = await _catalog.goodById(first.goodId);
    if (!mounted) return;
    if (good == null) {
      snack(t.stocktake.goodNotLoaded);
      return;
    }
    final here = !first.inBox && first.cellId == count.cell.cellId;
    final warehouseId = here
        ? first.internalWarehouseId
        : count
              .positionsOf(good.id)
              .where((p) => p.productionDate == first.productionDate)
              .firstOrNull
              ?.internalWarehouseId;
    cubit.addMarks(
      good: _good(good),
      productionDate: first.productionDate,
      internalWarehouseId: warehouseId,
      marks: [
        for (final m in found)
          if (m.goodId == first.goodId &&
              m.productionDate == first.productionDate)
            m.cis,
      ],
    );
  }

  /// Штрихкод товара: товар — из справочника терминала; не привязан — выбор и привязка
  /// очередью; проверить без связи не удалось — решение за кладовщиком (как во «Вводе остатков»).
  Future<void> _onGood(String code) async {
    final res = await _catalog.resolveGoodByBarcode(code);
    if (!mounted) return;
    if (res.isLeft) {
      final confirmed = await showBindPromptDialog(
        context,
        title: t.stockEntry.bindOfflineTitle,
        body: res.left is NetworkFailure
            ? t.stockEntry.barcodeOffline(barcode: code)
            : t.stockEntry.barcodeLookupFailed(barcode: code),
        confirmLabel: t.stockEntry.bindOfflineConfirm,
        cancelLabel: t.stockEntry.bindOfflineCancel,
      );
      if (!confirmed || !mounted) return;
      await _pickAndBind(code);
      return;
    }
    final good = res.right;
    if (good == null) {
      snack(t.stocktake.goodNotBound);
      await _pickAndBind(code);
      return;
    }
    await countGood(good);
  }

  /// Выбрать товар и привязать ему ШК очередью — затем посчитать.
  Future<void> _pickAndBind(String code) async {
    final picked = await pickGood();
    if (picked == null || !mounted) return;
    await _catalog.bindBarcode(goodId: picked.id, barcode: code);
    if (mounted) await countGood(picked);
  }

  /// Добавить товар вручную, без ШК.
  Future<void> addManual() async {
    final picked = await pickGood();
    if (picked != null && mounted) await countGood(picked);
    refocusScan();
  }

  /// Посчитать товар: позиция снимка (одна — сразу, несколько — выбор), иначе излишек
  /// «Основного». Маркируемый — только марками.
  Future<void> countGood(Good good) async {
    if (good.czMarked) {
      cubit.hintScanMark();
      return;
    }
    final positions = count.positionsOf(good.id);
    StocktakePosition? position;
    if (positions.length == 1) {
      position = positions.single;
    } else if (positions.length > 1) {
      final picked = await showPositionPickSheet(context, positions);
      if (picked == null || !mounted) return;
      position = picked.position;
    }
    await _askQty(_good(good), position);
  }

  /// Посчитать позицию снимка касанием — без скана.
  Future<void> countPosition(StocktakePosition p) async {
    if (p.marked) {
      cubit.hintScanMark();
      return;
    }
    await _askQty(p.good!, p);
    refocusScan();
  }

  /// Дата и количество; партия позиции подставлена. Другая дата — та же позиция другой партии.
  Future<void> _askQty(StocktakeGood good, StocktakePosition? position) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) => DateQtyDialog(
        good: Good(
          id: good.id,
          code: good.code,
          name: good.name,
          uom: good.uom,
        ),
        initialDate: position?.productionDate == null
            ? null
            : batchDate(position!.productionDate!),
      ),
    );
    if (res == null || res.wrongGood || !mounted) return;
    cubit.addQty(
      good: good,
      productionDate: res.date.replaceAll('.', '-'),
      internalWarehouseId: position?.internalWarehouseId,
      qty: res.qty,
    );
  }

  /// Исправить насчитанное позиции без марок.
  Future<void> editLine(CountLine line) async {
    final res = await showDialog<DateQtyResult>(
      context: context,
      builder: (_) => DateQtyDialog(
        good: Good(
          id: line.good.id,
          code: line.good.code,
          name: line.good.name,
          uom: line.good.uom,
        ),
        initialDate: batchDate(line.productionDate),
        initialQty: line.qty,
      ),
    );
    if (res == null || res.wrongGood || !mounted) return;
    cubit.editLine(
      line,
      productionDate: res.date.replaceAll('.', '-'),
      qty: res.qty,
    );
  }

  StocktakeGood _good(Good g) =>
      StocktakeGood(id: g.id, code: g.code ?? '', name: g.name, uom: g.uom);

  /// Нижний лист выбора товара из номенклатуры.
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
