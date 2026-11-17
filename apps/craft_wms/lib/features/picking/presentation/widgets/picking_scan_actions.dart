import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/load_unit/load_unit_code.dart';
import '../../../../core/scanner/cz_code.dart';
import '../../../../core/scanner/hardware_scan_listener.dart';
import '../../../../core/scanner/scan_code.dart';
import '../../../../core/scanner/scan_deduper.dart';
import '../../../../core/utils/serial_lock.dart';
import '../../../../core/widgets/qty_dialog.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../contents/domain/contents_repository.dart';
import '../../../stock/domain/catalog_repository.dart';
import '../../domain/picking_repository.dart';
import '../../domain/picking_sources.dart';
import '../../domain/picking_view.dart';
import '../bloc/picking_order_cubit.dart';
import 'picking_sheets.dart';

/// Скан при сборке заказа (P9-06): что за код и что из него взять.
///
/// Что: россыпь - сканом ячейки, товар в коробе - сканом короба хранения, маркируемый - сканом
/// марки, групповой упаковки или короба ЧЗ. Вариант берётся из подбора сервера; источника в нём
/// нет - из снимка склада терминала (сервер разрешает собирать из любого источника склада с
/// «разрешить сборку» и проверит остаток сам).
/// Зачем отдельно от экрана: правила «что за код» опираются на снимок и справочники
/// терминала - сборка идёт без связи.
/// Скорость (ADHOC-63): сканы обрабатываются строго по одному в порядке прихода ([_scans]) -
/// следующий видит заказ уже с пиком предыдущего; марка ищется только по данным терминала,
/// сеть на скан не ждётся. Время скана пишется в журнал - для замера на устройстве.
mixin PickingScanActions<T extends StatefulWidget>
    on State<T>, HardwareScanListener<T> {
  final scanController = TextEditingController();
  final scanFocus = FocusNode();
  final _deduper = ScanDeduper();
  final _scans = SerialLock();

  PickingOrderCubit get cubit => context.read<PickingOrderCubit>();
  ContentsRepository get _contents => getIt<ContentsRepository>();

  /// Показать снекбар с текстом.
  void snack(String text);

  @override
  void dispose() {
    scanController.dispose();
    scanFocus.dispose();
    super.dispose();
  }

  void refocusScan() {
    if (mounted) scanFocus.requestFocus();
  }

  @override
  void onHardwareScan(ScanCode code) => onScan(code.raw);

  /// Можно ли пикать: заказ в работе у этого кладовщика и короб отгрузки выбран.
  PickingOrderView? _ready() {
    final view = cubit.view;
    if (view == null) return null;
    if (!view.order.mine) {
      snack(t.picking.takeFirst);
      return null;
    }
    if (view.currentBoxId == null) {
      snack(t.picking.boxFirst);
      return null;
    }
    return view;
  }

  /// Единая точка для поля и интента сканера: скан встаёт в очередь сканов экрана.
  Future<void> onScan(String value) async {
    final code = value.trim();
    scanController.clear();
    if (code.isEmpty || !_deduper.allow(code)) {
      refocusScan();
      return;
    }
    final clock = Stopwatch()..start();
    try {
      await _scans.run(() => _handle(code, clock));
    } catch (e, s) {
      getIt<Talker>().handle(e, s, 'Сборка: скан не обработан');
    }
  }

  /// Обработать один скан; [clock] - с прихода скана, для замера.
  Future<void> _handle(String code, Stopwatch clock) async {
    if (!mounted) return;
    final waited = clock.elapsedMilliseconds;
    final view = _ready();
    if (view != null) {
      switch (classifyScan(code)) {
        case ScanKind.cell:
          await _onCell(view, code);
        case ScanKind.cargoUnit:
          await _onBox(view, loadUnitIdFrom(code)!);
        case ScanKind.czMark:
          await _onMarks(view, czMarkFrom(code)!);
        case ScanKind.czBox:
          await _onMarks(view, czBoxFrom(code)!);
        case ScanKind.good:
        case ScanKind.unknown:
          snack(t.picking.scanHint);
      }
    }
    refocusScan();
    getIt<Talker>().debug(
      'Сборка: скан обработан за ${clock.elapsedMilliseconds} мс '
      '(в очереди сканов $waited мс)',
    );
  }

  /// Россыпь ячейки.
  Future<void> _onCell(PickingOrderView view, String address) async {
    var candidates = candidatesFromTakes(view, cellAddress: address);
    if (candidates.isEmpty) {
      final ref = await _contents.findCell(address);
      if (!mounted) return;
      if (ref == null) {
        snack(t.picking.cellUnknown(cell: address));
        return;
      }
      final res = await _contents.cell(ref);
      if (!mounted) return;
      final loose = res.isRight
          ? res.right.value?.loose ?? const <ContentLine>[]
          : const <ContentLine>[];
      candidates = candidatesFromContents(
        view,
        contents: loose,
        cellAddress: ref.address,
        cellId: ref.id,
      );
    }
    await _pickFrom(view, candidates, t.picking.nothingInCell(cell: address));
  }

  /// Товар в коробе хранения.
  Future<void> _onBox(PickingOrderView view, String id) async {
    var candidates = candidatesFromTakes(view, loadUnitId: id);
    if (candidates.isEmpty) {
      final res = await _contents.loadUnit(id);
      if (!mounted) return;
      final lu = res.isRight ? res.right.value : null;
      if (lu == null) {
        snack(t.picking.boxUnknown);
        return;
      }
      candidates = candidatesFromContents(
        view,
        contents: lu.lines,
        cellAddress: lu.cellAddress ?? '',
        loadUnitId: lu.id,
      );
    }
    await _pickFrom(view, candidates, t.picking.nothingInBox);
  }

  /// Выбрать вариант, спросить количество и взять.
  Future<void> _pickFrom(
    PickingOrderView view,
    List<PickCandidate> candidates,
    String nothing,
  ) async {
    if (candidates.isEmpty) {
      // Маркируемый товар этого заказа здесь мог бы быть - он берётся только марками.
      final marked = view.activeLines.any((l) => l.czMarked && !view.done(l));
      snack(marked ? t.picking.nothingOrMarks(text: nothing) : nothing);
      return;
    }
    final c = candidates.length == 1
        ? candidates.single
        : await showCandidateSheet(context, candidates);
    if (c == null || !mounted) return;
    final qty = await showQtyDialog(
      context,
      max: c.available,
      uom: c.line.uom,
      title: t.picking.qtyTitle,
      header: candidateHeader(c),
    );
    if (qty == null || !mounted) return;
    await cubit.pick(_request(view, c, qty: qty));
  }

  /// Марки по скану марки, групповой упаковки или короба ЧЗ - пик сразу, без количества.
  Future<void> _onMarks(PickingOrderView view, String code) async {
    final found = await _contents.marksByCode(code);
    if (!mounted) return;
    final address = await _addressOf(found);
    if (!mounted) return;
    final res = candidateFromMarks(
      view,
      found: found,
      cellAddressOf: (_) => address,
    );
    final c = res.candidate;
    if (c == null) {
      snack(switch (res.problem!) {
        MarkPickProblem.unknown => t.picking.markUnknown,
        MarkPickProblem.already => t.picking.markAlready,
        MarkPickProblem.mixed => t.picking.markMixed,
        MarkPickProblem.noLine => t.picking.markNoLine,
        MarkPickProblem.tooMany => t.picking.markTooMany,
      });
      return;
    }
    await cubit.pick(
      _request(view, c, qty: res.marks.length.toDouble(), marks: res.marks),
    );
  }

  /// Адрес ячейки марок - для показа пика: у марки в коробе - ячейка короба.
  Future<String> _addressOf(List<StockMark> found) async {
    if (found.isEmpty) return '';
    final m = found.first;
    // Короб - из снимка терминала: запрос карточки на каждую марку ждал бы сеть.
    if (m.loadUnitId != null) {
      return await _contents.cachedLoadUnitCell(m.loadUnitId!) ?? '';
    }
    final cellId = m.cellId;
    if (cellId == null) return '';
    final cell = await getIt<CatalogRepository>().cachedCellById(cellId);
    return cell?.address ?? '';
  }

  PickRequest _request(
    PickingOrderView view,
    PickCandidate c, {
    required double qty,
    List<String> marks = const [],
  }) => PickRequest(
    orderId: view.order.id,
    lineId: c.line.id,
    sourceCellId: c.sourceCellId,
    sourceLoadUnitId: c.sourceLoadUnitId,
    cellAddress: c.cellAddress,
    internalWarehouseId: c.internalWarehouseId,
    productionDate: c.productionDate,
    qty: qty,
    marks: marks,
  );
}
