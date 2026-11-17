import '../../../core/gen/strings.g.dart';

/// Подписи статусов марки (CZ-04): в ЧЗ и на складе.

/// Статус в обороте по ЧЗ. Известные - словами, незнакомый - как пришёл: лучше код ЧЗ, чем
/// пустая строка.
String czStatusLabel(String? status) {
  final s = t.czScan.czStatuses;
  return switch (status?.toUpperCase()) {
    'INTRODUCED' => s.introduced,
    'APPLIED' => s.applied,
    'EMITTED' => s.emitted,
    'RETIRED' => s.retired,
    'WRITTEN_OFF' => s.writtenOff,
    _ => status ?? '',
  };
}

/// Статус марки в WMS.
String wmsMarkStatusLabel(String status) {
  final s = t.czScan.wmsStatuses;
  return switch (status) {
    'in_stock' => s.inStock,
    'shipped' => s.shipped,
    'written_off' => s.writtenOff,
    'returned' => s.returned,
    _ => status,
  };
}
