import 'package:craft_wms/core/outbox/outbox_operation.dart';
import 'package:craft_wms/features/contents/data/pending_overlay.dart';
import 'package:craft_wms/features/contents/domain/contents_entities.dart';
import 'package:flutter_test/flutter_test.dart';

/// Наложение своих неотправленных приёмок и размещений (P5-05): так, как их проведёт сервер.
void main() {
  const wh = 'wh-1';
  const receiving = 'cell-snp'; // ячейка приёмки «С-Н-П»
  const storage = 'cell-a1';
  const cells = OverlayCells(
    addressById: {receiving: 'С-Н-П', storage: 'A-1-1'},
    defaultCellByWarehouse: {wh: receiving},
  );
  final now = DateTime(2026, 10, 8, 12);
  var seq = 0;

  OutboxOperation op(
    OutboxKind kind,
    Map<String, dynamic> payload, {
    OutboxStatus status = OutboxStatus.pending,
  }) => OutboxOperation(
    seq: ++seq,
    operationId: 'op-$seq',
    kind: kind,
    payload: payload,
    status: status,
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  );

  /// Приёмка: короб `box` с 12 шт и россыпь 3 шт — в ячейку приёмки (ячейки в строках нет).
  OutboxOperation receipt({String box = 'box-1', OutboxStatus? status}) =>
      op(OutboxKind.receiptSubmit, {
        'warehouse_id': wh,
        'load_units': [
          {'id': box, 'kind': 'box'},
        ],
        'lines': [
          {
            'good_id': 'g1',
            'production_date': '01-09-2026',
            'qty': 12,
            'load_unit_id': box,
          },
          {'good_id': 'g1', 'production_date': '02-09-2026', 'qty': 3},
        ],
      }, status: status ?? OutboxStatus.pending);

  /// Размещение: короб `box` и 2 шт россыпи — в ячейку хранения.
  OutboxOperation putaway({String box = 'box-1'}) =>
      op(OutboxKind.putawaySubmit, {
        'warehouse_id': wh,
        'lines': [
          {'load_unit_id': box, 'to_cell_id': storage},
          {
            'good_id': 'g1',
            'production_date': '02-09-2026',
            'qty': '2',
            'to_cell_id': storage,
          },
        ],
      });

  CellView emptyCell(String id) =>
      CellView(cellId: id, address: cells.addressById[id]!);

  test('короб своей приёмки без связи виден в ячейке приёмки с пометкой', () {
    final overlay = PendingOverlay([receipt()], cells);

    final lu = overlay.applyToLoadUnit('box-1', null)!;
    expect(lu.cellId, receiving);
    expect(lu.cellAddress, 'С-Н-П');
    expect(lu.pending, isTrue);
    expect(lu.live, isTrue);
    expect(lu.lines.single.qty, 12);
    expect(lu.lines.single.pending, isTrue);

    final cell = overlay.applyToCell(emptyCell(receiving), const {});
    expect(cell.loadUnits.map((e) => e.id), ['box-1']);
    expect(cell.loose.single.qty, 3);
    expect(cell.loose.single.pending, isTrue);
  });

  test('приёмка, которую сервер уже знает, не удваивает содержимое короба', () {
    // Операция «отправляется», ответ не дошёл, а сервер её уже провёл — короб есть в ответе.
    final overlay = PendingOverlay([
      receipt(status: OutboxStatus.sending),
    ], cells);
    const fromServer = LoadUnitView(
      id: 'box-1',
      cellId: receiving,
      cellAddress: 'С-Н-П',
      live: true,
      lines: [ContentLine(goodId: 'g1', productionDate: '01-09-2026', qty: 12)],
    );

    final lu = overlay.applyToLoadUnit('box-1', fromServer)!;
    expect(lu.lines.single.qty, 12);
    expect(lu.pending, isFalse);
  });

  test('размещение переносит короб и россыпь из ячейки приёмки', () {
    final overlay = PendingOverlay([receipt(), putaway()], cells);

    final lu = overlay.applyToLoadUnit('box-1', null)!;
    expect(lu.cellId, storage);
    expect(lu.cellAddress, 'A-1-1');

    final snp = overlay.applyToCell(emptyCell(receiving), const {});
    expect(snp.loadUnits, isEmpty);
    expect(snp.loose.single.qty, 1); // 3 принято, 2 унесено

    final a1 = overlay.applyToCell(emptyCell(storage), const {});
    expect(a1.loadUnits.single.id, 'box-1');
    expect(a1.loadUnits.single.lines.single.qty, 12);
    expect(a1.loose.single.qty, 2);
  });

  test(
    'перенесённый короб берёт содержимое из снимка, ячейка-источник его теряет',
    () {
      // Короб уже на сервере (в снимке лежит в ячейке приёмки), размещение ещё в очереди.
      final overlay = PendingOverlay([putaway()], cells);
      const snapshotBox = LoadUnitView(
        id: 'box-1',
        cellId: receiving,
        live: true,
        lines: [
          ContentLine(goodId: 'g1', productionDate: '01-09-2026', qty: 12),
        ],
      );

      final a1 = overlay.applyToCell(emptyCell(storage), {
        'box-1': snapshotBox,
      });
      expect(a1.loadUnits.single.lines.single.qty, 12);
      expect(a1.loadUnits.single.pending, isTrue);

      final snp = overlay.applyToCell(
        const CellView(
          cellId: receiving,
          address: 'С-Н-П',
          loadUnits: [snapshotBox],
          loose: [
            ContentLine(goodId: 'g1', productionDate: '02-09-2026', qty: 2),
          ],
        ),
        {'box-1': snapshotBox},
      );
      expect(snp.loadUnits, isEmpty);
      expect(snp.loose, isEmpty); // 2 − 2: строка уходит, а не остаётся нулём
    },
  );

  test('отклонённые и отправленные операции не накладываются', () {
    final overlay = PendingOverlay([
      receipt(box: 'box-r', status: OutboxStatus.rejected),
      receipt(box: 'box-s', status: OutboxStatus.sent),
    ], cells);

    expect(overlay.ops, isEmpty);
    expect(overlay.applyToLoadUnit('box-r', null), isNull);
    expect(overlay.applyToLoadUnit('box-s', null), isNull);
  });

  test('сложение количеств не копит хвост double', () {
    final overlay = PendingOverlay([
      op(OutboxKind.receiptSubmit, {
        'warehouse_id': wh,
        'lines': [
          for (final q in ['0.1', '0.2'])
            {'good_id': 'g1', 'production_date': '01-09-2026', 'qty': q},
        ],
      }),
    ], cells);

    final cell = overlay.applyToCell(emptyCell(receiving), const {});
    expect(cell.loose.single.qty, 0.3);
  });

  // P6-04: своё неотправленное перемещение.
  test(
    'перемещение: короб едет целиком, товар — между коробами и россыпью',
    () {
      const other = 'cell-b2';
      const cellsMove = OverlayCells(
        addressById: {receiving: 'С-Н-П', storage: 'A-1-1', other: 'B-2'},
        defaultCellByWarehouse: {wh: receiving},
      );
      final move = op(OutboxKind.movementSubmit, {
        'movement_id': 'mv-1',
        'movement_kind': 'move',
        'warehouse_id': wh,
        'lines': [
          {'load_unit_id': 'box-1', 'to_cell_id': other},
          {
            'good_id': 'g1',
            'production_date': '01-09-2026',
            'qty': 3,
            'from_load_unit_id': 'box-2',
            'to_cell_id': storage,
          },
          {
            'good_id': 'g1',
            'production_date': '01-09-2026',
            'qty': 1,
            'from_cell_id': storage,
            'to_load_unit_id': 'box-1',
          },
        ],
      });
      final overlay = PendingOverlay([move], cellsMove);
      expect(overlay.referencedLoadUnits, {'box-1', 'box-2'});

      LoadUnitView box(String id) => LoadUnitView(
        id: id,
        cellId: storage,
        live: true,
        lines: const [
          ContentLine(goodId: 'g1', productionDate: '01-09-2026', qty: 12),
        ],
      );

      final box1 = overlay.applyToLoadUnit('box-1', box('box-1'))!;
      expect(box1.cellId, other);
      expect(box1.cellAddress, 'B-2');
      expect(box1.lines.single.qty, 13, reason: '12 + 1 из россыпи');
      expect(box1.pending, isTrue);

      final box2 = overlay.applyToLoadUnit('box-2', box('box-2'))!;
      expect(box2.cellId, storage);
      expect(box2.lines.single.qty, 9, reason: '12 − 3 в россыпь');

      final cell = overlay.applyToCell(
        CellView(cellId: storage, address: 'A-1-1', loadUnits: [box('box-2')]),
        {'box-1': box('box-1')},
      );
      expect(cell.loose.single.qty, 2, reason: '3 из короба − 1 в короб');
      expect(cell.loadUnits.map((lu) => lu.id), [
        'box-2',
      ], reason: 'box-1 уехал');
    },
  );
}
