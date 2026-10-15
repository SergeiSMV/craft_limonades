import '../domain/contents_entities.dart';

/// Разбор ответов `GET /contents/snapshot`, `GET /cells/{id}/contents`,
/// `GET /load-units/{id}/card` (P5-05) в сущности домена и строки снимка.
///
/// Руками, а не json_serializable: ответов три, домен — простые классы без кодогенерации,
/// и разбор в одном месте нагляднее аннотаций на двух слоях. Формат снимка закреплён
/// эталоном `apps/backend/internal/handler/testdata/contents_snapshot.json`.

/// Количество приходит строкой (decimal с сервера).
double _qty(Object? raw) => double.tryParse('$raw') ?? 0;

/// Строка содержимого карточки или ячейки — с наименованием товара. Склад строки — свой
/// у россыпи, у содержимого короба — [warehouseId] короба. Id склада — как прислал сервер;
/// к соглашению терминала («Основной» — `null`) его приводит репозиторий.
ContentLine contentLineFromJson(
  Map<String, dynamic> j, {
  String? warehouseId,
}) => ContentLine(
  goodId: j['good_id'] as String,
  goodName: j['good_name'] as String?,
  goodCode: j['good_code'] as String?,
  uom: j['uom'] as String?,
  productionDate: j['production_date'] as String,
  qty: _qty(j['qty']),
  internalWarehouseId: warehouseId ?? j['internal_warehouse_id'] as String?,
);

/// Карточка короба.
LoadUnitView loadUnitFromJson(Map<String, dynamic> j) {
  final warehouse = j['internal_warehouse_id'] as String?;
  return LoadUnitView(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'box',
    cellId: j['cell_id'] as String?,
    cellAddress: j['cell_address'] as String?,
    createdAt: DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
    live: j['live'] as bool? ?? false,
    internalWarehouseId: warehouse,
    lines: [
      for (final c in j['contents'] as List? ?? const [])
        contentLineFromJson(c as Map<String, dynamic>, warehouseId: warehouse),
    ],
  );
}

/// Содержимое ячейки.
CellView cellFromJson(Map<String, dynamic> j) => CellView(
  cellId: j['cell_id'] as String,
  address: j['address'] as String,
  loadUnits: [
    for (final lu in j['load_units'] as List? ?? const [])
      loadUnitFromJson(lu as Map<String, dynamic>),
  ],
  loose: [
    for (final l in j['loose'] as List? ?? const [])
      contentLineFromJson(l as Map<String, dynamic>),
  ],
);

/// Строка снимка: товар партии, как её хранит кэш.
class SnapshotLine {
  const SnapshotLine({
    required this.goodId,
    required this.batchId,
    required this.productionDate,
    required this.qty,
  });

  factory SnapshotLine.fromJson(Map<String, dynamic> j) => SnapshotLine(
    goodId: j['good_id'] as String,
    batchId: j['batch_id'] as String,
    productionDate: j['production_date'] as String,
    qty: _qty(j['qty']),
  );

  final String goodId;
  final String batchId;
  final String productionDate;
  final double qty;
}

/// Короб снимка.
class SnapshotLoadUnit {
  const SnapshotLoadUnit({
    required this.id,
    required this.kind,
    required this.cellId,
    required this.createdAt,
    required this.lines,
    this.internalWarehouseId = '',
  });

  factory SnapshotLoadUnit.fromJson(Map<String, dynamic> j) => SnapshotLoadUnit(
    id: j['id'] as String,
    kind: j['kind'] as String,
    cellId: j['cell_id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    internalWarehouseId: j['internal_warehouse_id'] as String? ?? '',
    lines: [
      for (final c in j['contents'] as List? ?? const [])
        SnapshotLine.fromJson(c as Map<String, dynamic>),
    ],
  );

  final String id;
  final String kind;
  final String cellId;
  final DateTime createdAt;
  final List<SnapshotLine> lines;

  /// Склад короба целиком (P6-07-2); пусто — сервер до P6-07-1.
  final String internalWarehouseId;
}

/// Россыпь снимка.
class SnapshotLoose {
  const SnapshotLoose({
    required this.cellId,
    required this.internalWarehouseId,
    required this.line,
  });

  factory SnapshotLoose.fromJson(Map<String, dynamic> j) => SnapshotLoose(
    cellId: j['cell_id'] as String,
    internalWarehouseId: j['internal_warehouse_id'] as String,
    line: SnapshotLine.fromJson(j),
  );

  final String cellId;
  final String internalWarehouseId;
  final SnapshotLine line;
}

/// Снимок содержимого склада целиком.
class ContentsSnapshot {
  const ContentsSnapshot({
    required this.asOf,
    required this.loadUnits,
    required this.loose,
  });

  factory ContentsSnapshot.fromJson(Map<String, dynamic> j) => ContentsSnapshot(
    asOf: DateTime.parse(j['as_of'] as String),
    loadUnits: [
      for (final lu in j['load_units'] as List? ?? const [])
        SnapshotLoadUnit.fromJson(lu as Map<String, dynamic>),
    ],
    loose: [
      for (final l in j['loose'] as List? ?? const [])
        SnapshotLoose.fromJson(l as Map<String, dynamic>),
    ],
  );

  /// Момент, на который согласован снимок (UTC).
  final DateTime asOf;
  final List<SnapshotLoadUnit> loadUnits;
  final List<SnapshotLoose> loose;
}

/// История короба (`GET /load-units/{id}/history`, P5-05-1).
LoadUnitHistory historyFromJson(Map<String, dynamic> j) {
  DateTime? at(Object? raw) =>
      DateTime.tryParse(raw as String? ?? '')?.toLocal();
  final receipt = j['receipt'] as Map<String, dynamic>?;
  return LoadUnitHistory(
    createdAt: at(j['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    receipt: receipt == null
        ? null
        : LoadUnitReceiptInfo(
            docNumber: receipt['doc_number'] as String?,
            docDate: receipt['doc_date'] as String?,
            receivedBy: receipt['received_by'] as String? ?? '',
            supplier: receipt['supplier'] as String?,
            postedAt: at(receipt['posted_at']),
          ),
    moves: [
      for (final m in j['moves'] as List? ?? const [])
        LoadUnitMove(
          from: (m as Map<String, dynamic>)['from'] as String?,
          to: m['to'] as String,
          kind: switch (m['source']) {
            'receipt' => LoadUnitMoveKind.receipt,
            'putaway' => LoadUnitMoveKind.putaway,
            'move' => LoadUnitMoveKind.move,
            _ => LoadUnitMoveKind.other,
          },
          userName: m['user_name'] as String?,
          at: at(m['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ],
  );
}
