import '../../../core/outbox/outbox_operation.dart';
import '../domain/contents_entities.dart';

/// Ячейки, которые нужны наложению: адреса и ячейка приёмки каждого склада.
class OverlayCells {
  const OverlayCells({
    this.addressById = const {},
    this.defaultCellByWarehouse = const {},
  });

  final Map<String, String> addressById;

  /// Ячейка приёмки («С-Н-П») склада: туда приёмка кладёт строку без ячейки, оттуда
  /// размещение берёт россыпь (P5-02).
  final Map<String, String> defaultCellByWarehouse;
}

/// Свои неотправленные приёмки и размещения поверх данных сервера или снимка (P5-05).
///
/// Что: применяет к короба́м и россыпи операции очереди `receipt_submit` и `putaway_submit`
/// в статусах «ожидает» и «отправляется» — так, как их проведёт сервер.
/// Зачем: без этого короб из своей приёмки без связи «не существует», а перенесённый своим
///        размещением — лежит в старой ячейке. Кладовщик пошёл бы искать его не туда.
/// Как: при чтении, а не записью в кэш: снимок заменяется целиком и стёр бы записанное.
///      Отклонённые операции сюда не попадают — их не было. Всё изменённое помечается
///      `pending`, чтобы не выдавать очередь за факт.
///
/// Правила сервера, которые здесь повторены: строка приёмки без ячейки ложится в ячейку
/// приёмки склада; россыпь размещения уходит из ячейки приёмки; короб переезжает целиком.
class PendingOverlay {
  PendingOverlay(Iterable<OutboxOperation> operations, this.cells)
    : ops = [
        for (final op in operations)
          if ((op.kind == OutboxKind.receiptSubmit ||
                  op.kind == OutboxKind.putawaySubmit) &&
              (op.status == OutboxStatus.pending ||
                  op.status == OutboxStatus.sending))
            op,
      ]..sort((a, b) => a.seq.compareTo(b.seq));

  /// Операции, которые накладываются, в порядке очереди.
  final List<OutboxOperation> ops;
  final OverlayCells cells;

  /// Короба, которые упоминают операции, — их содержимое надо достать из снимка заранее:
  /// размещение переносит короб, не повторяя, что в нём.
  Set<String> get referencedLoadUnits => {
    for (final op in ops)
      ..._lines(op).map((l) => l['load_unit_id']).whereType<String>(),
  };

  /// Короб с наложенными операциями. [base] — с сервера или из снимка, `null` — не найден.
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
  /// [known] — короба из снимка, которые упоминают операции (см. [referencedLoadUnits]):
  /// короб, перенесённый в эту ячейку своим размещением, берёт содержимое оттуда.
  /// Короба самой ячейки берутся из [base] — он свежее снимка, если пришёл с сервера.
  CellView applyToCell(CellView base, Map<String, LoadUnitView> known) {
    final boxes = <String, LoadUnitView>{
      for (final e in known.entries)
        if (e.value.cellId != base.cellId) e.key: e.value,
      for (final lu in base.loadUnits) lu.id: lu,
    };
    final loose = [...base.loose];
    _run(boxes, cellId: base.cellId, loose: loose);
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

  /// Прогнать операции по коробам и россыпи ячейки [cellId].
  ///
  /// [only] — следить только за этим коробом (карточка короба): остальное не нужно.
  void _run(
    Map<String, LoadUnitView> boxes, {
    String? only,
    String? cellId,
    List<ContentLine>? loose,
  }) {
    // Короба, которые знает сервер (ответ или снимок), до наложения. Короб заводит только
    // его приёмка, поэтому известный серверу короб значит «эта приёмка уже проведена» —
    // так бывает с операцией «отправляется», ответ на которую не дошёл. Её строки по коробу
    // не накладываются, иначе содержимое удвоилось бы. Россыпь приёмки так не распознать:
    // окно — время одной отправки, пометка «ожидает» на строке честно говорит о нём.
    final known = boxes.keys.toSet();
    for (final op in ops) {
      final warehouse = op.payload['warehouse_id'] as String?;
      final receivingCell = cells.defaultCellByWarehouse[warehouse];
      final isReceipt = op.kind == OutboxKind.receiptSubmit;
      for (final l in _lines(op)) {
        final box = l['load_unit_id'] as String?;
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
            );
          } else if (loose != null && cell == cellId) {
            _replace(loose, _add(loose, line));
          }
          continue;
        }
        final to = l['to_cell_id'] as String?;
        if (box != null) {
          // Короба нет ни на сервере, ни в снимке — переносим что знаем: его самого.
          final lu = boxes[box] ?? LoadUnitView(id: box, live: true);
          boxes[box] = lu.copyWith(cellId: to, pending: true);
        } else if (loose != null) {
          final line = _line(l);
          if (receivingCell == cellId) _replace(loose, _sub(loose, line));
          if (to == cellId) _replace(loose, _add(loose, line));
        }
      }
    }
  }

  LoadUnitView? _addressed(LoadUnitView? lu) {
    if (lu == null || !lu.pending || lu.cellId == null) return lu;
    final address = cells.addressById[lu.cellId];
    return address == null ? lu : lu.copyWith(cellAddress: address);
  }

  static List<Map<String, dynamic>> _lines(OutboxOperation op) => [
    for (final l in op.payload['lines'] as List? ?? const [])
      l as Map<String, dynamic>,
  ];

  /// Строка операции как строка содержимого. Количество в теле — число (приёмка) или строка
  /// (размещение берёт его из задания).
  static ContentLine _line(Map<String, dynamic> l) => ContentLine(
    goodId: l['good_id'] as String,
    productionDate: l['production_date'] as String,
    qty: double.tryParse('${l['qty']}') ?? 0,
    pending: true,
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

  /// Количество — до тысячных, как numeric(20,3) на сервере: сложение double иначе даёт
  /// «11.999999» там, где лежит 12.
  static double _round(double q) => (q * 1000).roundToDouble() / 1000;
}
