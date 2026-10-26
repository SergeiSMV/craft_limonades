import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';

/// Подписи значений транспорта пересчёта в портале (P10-05).

/// Виды области — в порядке выбора при заведении.
const kStocktakeScopes = [
  'cells',
  'group',
  'supplier',
  'good',
  'internal_warehouse',
  'all',
];

/// Вид области пересчёта.
String scopeLabel(String kind) => switch (kind) {
  'cells' => t.portal.stocktake.scopeCells,
  'group' => t.portal.stocktake.scopeGroup,
  'supplier' => t.portal.stocktake.scopeSupplier,
  'good' => t.portal.stocktake.scopeGood,
  'internal_warehouse' => t.portal.stocktake.scopeInternalWarehouse,
  'all' => t.portal.stocktake.scopeAll,
  _ => kind,
};

/// Статус пересчёта.
String stocktakeStatusLabel(String status) => switch (status) {
  'new' => t.portal.stocktake.statusNew,
  'in_progress' => t.portal.stocktake.statusInProgress,
  'closed' => t.portal.stocktake.statusClosed,
  _ => status,
};

/// Статус ячейки пересчёта.
String cellStatusLabel(String status) => switch (status) {
  'pending' => t.portal.stocktake.cellPending,
  'taken' => t.portal.stocktake.cellTaken,
  'counting' => t.portal.stocktake.cellCounting,
  'counted' => t.portal.stocktake.cellCounted,
  'disrupted' => t.portal.stocktake.cellDisrupted,
  _ => status,
};

/// Дата и время в локальной зоне: «26.10.2026 12:00».
String portalDateTime(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
}

/// Текст ошибки: отказ по существу сервер объясняет сам.
String stocktakeErrorText(Failure f) => switch (f) {
  ServerFailure(:final message, :final statusCode) =>
    message ?? 'HTTP $statusCode',
  NetworkFailure() => t.portal.login.errorNetwork,
  _ => t.portal.login.errorUnknown,
};
