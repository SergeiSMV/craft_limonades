import '../../../core/outbox/outbox_operation.dart';
import '../../../core/warehouse/internal_warehouses.dart';
import '../domain/contents_entities.dart';

/// Ячейки, которые нужны наложению: адреса и ячейка приёмки каждого склада.
class OverlayCells {
  const OverlayCells({
    this.addressById = const {},
    this.defaultCellByWarehouse = const {},
    this.defaultInternalWarehouse,
  });

  final Map<String, String> addressById;

  /// Id склада по умолчанию («Основной») - операции очереди несут id складов, а сущности
  /// терминала зовут его `null` (P6-07-2).
  final String? defaultInternalWarehouse;

  /// Ячейка приёмки («ПРИЁМКА») склада: туда приёмка кладёт строку без ячейки, оттуда
  /// размещение берёт россыпь (P5-02).
  final Map<String, String> defaultCellByWarehouse;
}

/// Россыпь ячейки, которую ведёт наложение; `null` - ячейка не нужна.
typedef _LooseOf = List<ContentLine>? Function(String cellId);

/// Свои неотправленные приёмки, размещения, движения и пометки брака поверх данных сервера
/// или снимка (P5-05, P6-04, P6-07-2).
///
/// Что: применяет к короба́м и россыпи операции очереди `receipt_submit`, `putaway_submit` и
/// `movement_submit` в статусах «ожидает» и «отправляется» - так, как их проведёт сервер.
/// Зачем: без этого короб из своей приёмки без связи «не существует», а перенесённый своим
///        размещением - лежит в старой ячейке. Кладовщик пошёл бы искать его не туда.
/// Как: при чтении, а не записью в кэш: снимок заменяется целиком и стёр бы записанное.
///      Отклонённые операции сюда не попадают - их не было. Всё изменённое помечается
///      `pending`, чтобы не выдавать очередь за факт.
///
/// Правила сервера, которые здесь повторены: строка приёмки без ячейки ложится в ячейку
/// приёмки склада; россыпь размещения уходит из ячейки приёмки; короб переезжает целиком;
/// товар движения уходит из короба или россыпи источника и ложится в короб или россыпь
/// приёмника; пометка (`problem_submit`) переводит короб целиком на другой склад, а товар -
/// из россыпи или короба в россыпь склада назначения той же ячейки. Склад строки - свой
/// у россыпи и склад короба у его содержимого.
class PendingOverlay {
  PendingOverlay(Iterable<OutboxOperation> operations, this.cells)
    : ops = [
        for (final op in operations)
          if ((op.kind == OutboxKind.receiptSubmit ||
                  op.kind == OutboxKind.putawaySubmit ||
                  op.kind == OutboxKind.movementSubmit ||
                  op.kind == OutboxKind.problemSubmit) &&
              (op.status == OutboxStatus.pending ||
                  op.status == OutboxStatus.sending))
            op,
      ]..sort((a, b) => a.seq.compareTo(b.seq));

  /// Операции, которые накладываются, в порядке очереди.
  final List<OutboxOperation> ops;
  final OverlayCells cells;

  /// Короба, которые упоминают операции, - их содержимое надо достать из снимка заранее:
  /// размещение переносит короб, не повторяя, что в нём.
  Set<String> get referencedLoadUnits => {
    for (final op in ops)
      for (final l in [
        ..._lines(op),
        if (op.kind == OutboxKind.problemSubmit) op.payload,
      ])
        for (final key in const [
          'load_unit_id',
          'from_load_unit_id',
          'to_load_unit_id',
        ])
          if (l[key] case final String id) id,
  };

  /// ГЕ короба ЧЗ с кодом [czCode] из своей неотправленной приёмки (CZ-06); `null` - нет.
  String? loadUnitIdByCzCode(String czCode) {
    for (final op in ops) {
      if (op.kind != OutboxKind.receiptSubmit) continue;
      for (final lu in op.payload['load_units'] as List? ?? const []) {
        final m = lu as Map<String, dynamic>;
        if (m['cz_code'] == czCode) return m['id'] as String?;
      }
    }
    return null;
  }

  /// Марки по коду [code] с наложенными операциями (CZ-06): своя приёмка добавляет марки,
  /// размещение, движение и пометка переносят их туда, куда переехал товар строки.
  ///
  /// [base] - марки снимка (КИ → марка); [boxes] - короба с наложенной очередью: марка из
  /// короба ложится в его ячейку и склад. Марка подходит, если её КИ - [code] или её упаковка -
  /// [code] (скан групповой упаковки).
  Map<String, StockMark> applyToMarks(
    Map<String, StockMark> base,
    String code, {
    Map<String, LoadUnitView> boxes = const {},
  }) {
    final out = {...base};
    for (final op in ops) {
      final p = op.payload;
      if (op.kind == OutboxKind.problemSubmit) {
        final to = _warehouse(p['to_internal_warehouse_id']);
        final fromBox = p['from_load_unit_id'] as String?;
        final cell = p['cell_id'] as String? ?? boxes[fromBox]?.cellId;
        for (final cis in _marks(p)) {
          final m = out[cis];
          if (m != null) {
            out[cis] = m.movedTo(cellId: cell, internalWarehouseId: to);
          }
        }
        continue;
      }
      final receivingCell =
          cells.defaultCellByWarehouse[p['warehouse_id'] as String?];
      for (final l in _lines(op)) {
        if (op.kind == OutboxKind.receiptSubmit) {
          for (final raw in l['marks'] as List? ?? const []) {
            final m = raw as Map<String, dynamic>;
            final cis = m['cis'] as String;
            final agg = m['aggregate_code'] as String?;
            if (cis != code && agg != code) continue;
            final box = l['load_unit_id'] as String?;
            out[cis] = StockMark(
              cis: cis,
              goodId: l['good_id'] as String,
              productionDate: l['production_date'] as String,
              loadUnitId: box,
              cellId: box == null
                  ? l['cell_id'] as String? ?? receivingCell
                  : null,
              aggregateCode: agg,
              pending: true,
            );
          }
          continue;
        }
        final toBox = l['to_load_unit_id'] as String?;
        final fromBox = l['from_load_unit_id'] as String?;
        // Склад товара: россыпь - склад строки, из короба - склад короба (P6-07-1).
        final iwh = fromBox != null
            ? boxes[fromBox]?.internalWarehouseId
            : _warehouse(l['internal_warehouse_id']);
        for (final cis in _marks(l)) {
          final m = out[cis];
          if (m == null) continue;
          out[cis] = m.movedTo(
            loadUnitId: toBox,
            cellId: l['to_cell_id'] as String?,
            internalWarehouseId: iwh,
          );
        }
      }
    }
    return out;
  }

  /// КИ марок строки или пометки (CZ-06).
  static List<String> _marks(Map<String, dynamic> l) => [
    for (final m in l['marks'] as List? ?? const []) m as String,
  ];

  /// Короб с наложенными операциями. [base] - с сервера или из снимка, `null` - не найден.
  LoadUnitView? applyToLoadUnit(String id, LoadUnitView? base) {
    final boxes = <String, LoadUnitView>{id: ?base};
    _run(boxes, only: id);
    return _addressed(boxes[id]);
  }

  /// Все короба склада с наложенными операциями (P5-05-1): короба своих неотправленных приёмок
  /// добавляются, переносы своих размещений меняют ячейку. Россыпь не трогается.
  Map<String, LoadUnitView> applyToAll(Map<String, LoadUnitView> base) {
    final boxes = {...base};
    _run(boxes);
    return boxes.map((id, lu) => MapEntry(id, _addressed(lu)!));
  }

  /// Ячейка с наложенными операциями.
  ///
  /// [known] - короба из снимка, которые упоминают операции (см. [referencedLoadUnits]):
  /// короб, перенесённый в эту ячейку своим размещением, берёт содержимое оттуда.
  /// Короба самой ячейки берутся из [base] - он свежее снимка, если пришёл с сервера.
  CellView applyToCell(CellView base, Map<String, LoadUnitView> known) {
    final boxes = <String, LoadUnitView>{
      for (final e in known.entries)
        if (e.value.cellId != base.cellId) e.key: e.value,
      for (final lu in base.loadUnits) lu.id: lu,
    };
    final loose = [...base.loose];
    _run(boxes, looseOf: (cell) => cell == base.cellId ? loose : null);
    return CellView(
      cellId: base.cellId,
      address: base.address,
      loadUnits: [
        for (final lu in boxes.values)
          if (lu.cellId == base.cellId) _addressed(lu)!,
      ],
      loose: loose,
    );
  }

  /// Весь склад с наложенными операциями (ADHOC-33): короба и россыпь всех ячеек - для
  /// остатков по товарам. [loose] - россыпь снимка по ячейкам; меняется на месте, ячейки,
  /// где россыпь появилась только из очереди, добавляются.
  Map<String, LoadUnitView> applyToWarehouse(
    Map<String, LoadUnitView> base,
    Map<String, List<ContentLine>> loose,
  ) {
    final boxes = {...base};
    _run(boxes, looseOf: (cell) => loose.putIfAbsent(cell, () => []));
    return boxes.map((id, lu) => MapEntry(id, _addressed(lu)!));
  }

  /// Прогнать операции по коробам и россыпи.
  ///
  /// [only] - следить только за этим коробом (карточка короба): остальное не нужно.
  /// [looseOf] - россыпь ячейки, которую надо вести, или `null`, если ячейка не нужна:
  /// карточке ячейки - одна ячейка, остаткам по товарам - все (ADHOC-33).
  void _run(
    Map<String, LoadUnitView> boxes, {
    String? only,
    _LooseOf? looseOf,
  }) {
    // Короба, которые знает сервер (ответ или снимок), до наложения. Короб заводит только
    // его приёмка, поэтому известный серверу короб значит «эта приёмка уже проведена» -
    // так бывает с операцией «отправляется», ответ на которую не дошёл. Её строки по коробу
    // не накладываются, иначе содержимое удвоилось бы. Россыпь приёмки так не распознать:
    // окно - время одной отправки, пометка «ожидает» на строке честно говорит о нём.
    final known = boxes.keys.toSet();
    for (final op in ops) {
      if (op.kind == OutboxKind.problemSubmit) {
        _problem(op.payload, boxes, only: only, looseOf: looseOf);
        continue;
      }
      final warehouse = op.payload['warehouse_id'] as String?;
      final receivingCell = cells.defaultCellByWarehouse[warehouse];
      final isReceipt = op.kind == OutboxKind.receiptSubmit;
      // Коды коробов ЧЗ приёмки (CZ-06): короб ЧЗ из своей очереди узнаётся по SSCC.
      final czCodes = <String, String>{
        if (isReceipt)
          for (final lu in op.payload['load_units'] as List? ?? const [])
            if ((lu as Map<String, dynamic>)['cz_code'] case final String code)
              lu['id'] as String: code,
      };
      for (final l in _lines(op)) {
        final box = l['load_unit_id'] as String?;
        if (op.kind == OutboxKind.movementSubmit && box == null) {
          _moveGoods(l, boxes, only: only, looseOf: looseOf);
          continue;
        }
        if (only != null && box != only) continue;
        if (isReceipt) {
          final cell = l['cell_id'] as String? ?? receivingCell;
          final line = _line(l);
          if (box != null) {
            if (known.contains(box)) continue;
            final lu =
                boxes[box] ??
                LoadUnitView(id: box, live: false, lines: const []);
            boxes[box] = lu.copyWith(
              cellId: cell,
              live: true,
              pending: true,
              lines: _add(lu.lines, line),
              czCode: czCodes[box],
            );
          } else if (_loose(looseOf, cell) case final loose?) {
            _replace(loose, _add(loose, line));
          }
          continue;
        }
        final to = l['to_cell_id'] as String?;
        if (box != null) {
          // Короба нет ни на сервере, ни в снимке - переносим что знаем: его самого.
          final lu = boxes[box] ?? LoadUnitView(id: box, live: true);
          boxes[box] = lu.copyWith(cellId: to, pending: true);
        } else {
          final line = _line(l);
          if (_loose(looseOf, receivingCell) case final from?) {
            _replace(from, _sub(from, line));
          }
          if (_loose(looseOf, to) case final into?) {
            _replace(into, _add(into, line));
          }
        }
        // Склада у строк приёмки и размещения нет: всё приходует и разносит «Основной».
      }
    }
  }

  /// Товар строки движения: из короба или россыпи источника - в короб или россыпь приёмника.
  ///
  /// Короб меняется, только если он уже есть в [boxes] (известен серверу, снимку или своей
  /// очереди): состав неизвестного короба выдумывать нечем.
  void _moveGoods(
    Map<String, dynamic> l,
    Map<String, LoadUnitView> boxes, {
    String? only,
    _LooseOf? looseOf,
  }) {
    final fromBox = l['from_load_unit_id'] as String?;
    final toBox = l['to_load_unit_id'] as String?;
    // Склад товара: из короба - склад короба, из россыпи - склад строки.
    final line = fromBox != null && boxes[fromBox] != null
        ? _line(l).onWarehouse(boxes[fromBox]!.internalWarehouseId)
        : _line(l);
    for (final (id, add) in [(fromBox, false), (toBox, true)]) {
      if (id == null || (only != null && id != only)) continue;
      final lu = boxes[id];
      if (lu == null) continue;
      boxes[id] = lu.copyWith(
        pending: true,
        lines: add ? _add(lu.lines, line) : _sub(lu.lines, line),
      );
    }
    if (fromBox == null) {
      if (_loose(looseOf, l['from_cell_id']) case final from?) {
        _replace(from, _sub(from, line));
      }
    }
    if (toBox == null) {
      if (_loose(looseOf, l['to_cell_id']) case final into?) {
        _replace(into, _add(into, line));
      }
    }
  }

  /// Пометка брака (P6-07-2): короб целиком - на склад назначения со всем составом; товар -
  /// из россыпи или короба в россыпь склада назначения той же ячейки.
  void _problem(
    Map<String, dynamic> p,
    Map<String, LoadUnitView> boxes, {
    String? only,
    _LooseOf? looseOf,
  }) {
    final to = _warehouse(p['to_internal_warehouse_id']);
    final box = p['load_unit_id'] as String?;
    if (box != null) {
      if (only != null && box != only) return;
      final lu = boxes[box];
      if (lu != null) {
        boxes[box] = lu.onWarehouse(to).copyWith(pending: true);
      }
      return;
    }
    final fromBox = p['from_load_unit_id'] as String?;
    if (fromBox != null) {
      final lu = boxes[fromBox];
      if (lu == null) return;
      final line = _line(p).onWarehouse(lu.internalWarehouseId);
      if (only == null || only == fromBox) {
        boxes[fromBox] = lu.copyWith(
          pending: true,
          lines: _sub(lu.lines, line),
        );
      }
      if (_loose(looseOf, lu.cellId) case final loose?) {
        _replace(loose, _add(loose, line.onWarehouse(to)));
      }
      return;
    }
    final loose = _loose(looseOf, p['cell_id']);
    if (loose == null) return;
    final line = _line(p);
    _replace(loose, _sub(loose, line));
    _replace(loose, _add(loose, line.onWarehouse(to)));
  }

  /// Россыпь ячейки [cell], если её надо вести; ячейки нет (`null`) - вести нечего.
  static List<ContentLine>? _loose(_LooseOf? looseOf, Object? cell) =>
      looseOf != null && cell is String ? looseOf(cell) : null;

  LoadUnitView? _addressed(LoadUnitView? lu) {
    if (lu == null || !lu.pending || lu.cellId == null) return lu;
    final address = cells.addressById[lu.cellId];
    return address == null ? lu : lu.copyWith(cellAddress: address);
  }

  static List<Map<String, dynamic>> _lines(OutboxOperation op) => [
    for (final l in op.payload['lines'] as List? ?? const [])
      l as Map<String, dynamic>,
  ];

  /// Строка операции как строка содержимого. Количество в теле - число (приёмка) или строка
  /// (размещение берёт его из задания). Склад - `internal_warehouse_id` строки (россыпь
  /// движения и пометки), без него - «Основной».
  ContentLine _line(Map<String, dynamic> l) => ContentLine(
    goodId: l['good_id'] as String,
    productionDate: l['production_date'] as String,
    qty: double.tryParse('${l['qty']}') ?? 0,
    pending: true,
    internalWarehouseId: _warehouse(l['internal_warehouse_id']),
  );

  /// Id склада из операции - в соглашение терминала: «Основной» - `null`.
  String? _warehouse(Object? id) => InternalWarehouses.normalize(
    id as String?,
    cells.defaultInternalWarehouse,
  );

  static List<ContentLine> _add(List<ContentLine> lines, ContentLine add) {
    final out = [...lines];
    final i = out.indexWhere(add.sameBatch);
    if (i < 0) return out..add(add);
    out[i] = out[i].copyWith(qty: _round(out[i].qty + add.qty), pending: true);
    return out;
  }

  static List<ContentLine> _sub(List<ContentLine> lines, ContentLine sub) {
    final out = [...lines];
    final i = out.indexWhere(sub.sameBatch);
    if (i < 0) return out;
    final left = _round(out[i].qty - sub.qty);
    if (left <= 0) return out..removeAt(i);
    out[i] = out[i].copyWith(qty: left, pending: true);
    return out;
  }

  static void _replace(List<ContentLine> target, List<ContentLine> with_) =>
      target
        ..clear()
        ..addAll(with_);

  /// Количество - до тысячных, как numeric(20,3) на сервере: сложение double иначе даёт
  /// «11.999999» там, где лежит 12.
  static double _round(double q) => (q * 1000).roundToDouble() / 1000;
}
