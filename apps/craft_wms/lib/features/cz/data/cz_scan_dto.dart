import '../domain/cz_scan.dart';

/// Разбор ответа `POST cz/scan` (CZ-04). Формат закреплён эталонами сервера
/// `backend/internal/handler/testdata/cz_scan_mark.json` и `cz_scan_box.json`: тест разбирает
/// те же файлы, что сервер обязан отдавать.
CzScanResult czScanFromJson(Map<String, dynamic> j) {
  final cz = (j['cz'] as Map<String, dynamic>?) ?? const {};
  return CzScanResult(
    code: j['code'] as String,
    kind: _kind(j['kind'] as String?),
    productName: cz['product_name'] as String?,
    gtin: cz['gtin'] as String?,
    productGroup: cz['product_group'] as String?,
    status: cz['status'] as String?,
    ownerInn: cz['owner_inn'] as String?,
    ownerName: cz['owner_name'] as String?,
    producedDate: _day(cz['produced_date']),
    expirationDate: _day(cz['expiration_date']),
    parent: cz['parent'] as String?,
    good: _good(j['good']),
    bindBarcode: j['bind_barcode'] as String?,
    unboundBarcode: j['unbound_barcode'] as String?,
    mark: _mark(j['mark']),
    loadUnitId: j['load_unit_id'] as String?,
    composition: [
      for (final l in (j['composition'] as List?) ?? const [])
        _line(l as Map<String, dynamic>),
    ],
    units: (j['units'] as num?)?.toInt() ?? 0,
    unreadable: [
      for (final c in (j['unreadable'] as List?) ?? const []) c as String,
    ],
    discrepancy: _text(j['discrepancy']),
    groups: [
      for (final g in (j['groups'] as List?) ?? const [])
        CzGroupRef(
          code: (g as Map<String, dynamic>)['code'] as String,
          parentCode: (g['parent_code'] as String?) ?? '',
        ),
    ],
    parents: {
      for (final e
          in ((j['parents'] as Map<String, dynamic>?) ?? const {}).entries)
        e.key: e.value as String,
    },
  );
}

/// Непустая строка или `null`: сервер опускает пустые поля, но и пустую строку считаем «нет».
String? _text(Object? v) => v is String && v.isNotEmpty ? v : null;

/// Вид кода: неизвестное значение считаем маркой — карточка товара покажет то, что есть.
CzCodeKind _kind(String? v) => switch (v) {
  'BOX' => CzCodeKind.box,
  'GROUP' => CzCodeKind.group,
  _ => CzCodeKind.unit,
};

CzGood? _good(Object? v) {
  if (v is! Map<String, dynamic>) return null;
  return CzGood(id: v['id'] as String, name: v['name'] as String);
}

CzMarkInWms? _mark(Object? v) {
  if (v is! Map<String, dynamic>) return null;
  return CzMarkInWms(
    status: v['status'] as String,
    receivedAt: DateTime.parse(v['received_at'] as String),
    loadUnitId: v['load_unit_id'] as String?,
    loadUnitCellId: v['load_unit_cell_id'] as String?,
    cellId: v['cell_id'] as String?,
    aggregateCode: v['aggregate_code'] as String?,
    cellAddress: v['cell_address'] as String?,
  );
}

CzCompositionLine _line(Map<String, dynamic> j) => CzCompositionLine(
  gtin: j['gtin'] as String,
  productName: (j['product_name'] as String?) ?? '',
  good: _good(j['good']),
  producedDate: _day(j['produced_date']),
  count: (j['count'] as num).toInt(),
  cis: [for (final c in (j['cis'] as List?) ?? const []) c as String],
  discrepancy: _text(j['discrepancy']),
);

/// Дата ЧЗ днём (`YYYY-MM-DD`); пусто или не дата — `null`.
DateTime? _day(Object? v) => v is String ? DateTime.tryParse(v) : null;
