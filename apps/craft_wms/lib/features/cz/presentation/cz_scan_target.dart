import '../domain/cz_scan.dart';

/// Куда вести кладовщика по ответу на скан «Честного знака» (CZ-04).
enum CzScanTarget {
  /// Марка известного товара — его карточка с блоком марки.
  goodCard,

  /// Марка товара с незнакомым GTIN — привязать ШК к товару поиском, затем карточка.
  bindBarcode,

  /// В ответе ЧЗ нет GTIN — товар не определить.
  noGtin,

  /// Короб, принятый на склад, — карточка ГЕ.
  loadUnit,

  /// Короб, ещё не принятый, или групповая упаковка — состав по ЧЗ.
  composition,
}

/// Решение «куда вести» — отдельно от экрана: одно правило для всех мест скана и его можно
/// проверить без страниц.
CzScanTarget czScanTarget(CzScanResult r) => switch (r.kind) {
  CzCodeKind.unit when r.good != null => CzScanTarget.goodCard,
  CzCodeKind.unit when r.bindBarcode != null => CzScanTarget.bindBarcode,
  CzCodeKind.unit => CzScanTarget.noGtin,
  CzCodeKind.box when r.loadUnitId != null => CzScanTarget.loadUnit,
  CzCodeKind.box || CzCodeKind.group => CzScanTarget.composition,
};
