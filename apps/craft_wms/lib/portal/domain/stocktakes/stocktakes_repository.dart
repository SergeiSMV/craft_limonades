import 'package:either_dart/either.dart';

import '../../../core/error/failure.dart';

/// Пересчёт в списке портала (P10-05): шапка и ход.
class PortalStocktake {
  const PortalStocktake({
    required this.id,
    required this.number,
    required this.scopeKind,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    required this.closedAt,
    required this.cells,
    required this.counted,
  });

  factory PortalStocktake.fromJson(Map<String, dynamic> j) => PortalStocktake(
    id: j['id'] as String,
    number: (j['number'] as num).toInt(),
    scopeKind: j['scope_kind'] as String? ?? '',
    status: j['status'] as String? ?? '',
    createdBy: j['created_by'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
    closedAt: j['closed_at'] == null
        ? null
        : DateTime.parse(j['closed_at'] as String),
    cells: (j['cells'] as num?)?.toInt() ?? 0,
    counted: (j['counted'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final int number;
  final String scopeKind;
  final String status;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? closedAt;
  final int cells;
  final int counted;

  bool get closed => status == 'closed';
}

/// Ячейка пересчёта в ходе выполнения: адрес, статус, кто держит.
typedef PortalStocktakeCell = ({String address, String status, String takenBy});

/// Строка пересчёта для окна «Ход»: в какой ячейке, что (товар с партией или короб), сколько
/// ожидалось по снимку и сколько посчитано (`fact == null` - ячейку не считали); `problem` -
/// недостача ушла проблемой «не найдено».
typedef PortalStocktakeLine = ({
  String cell,
  String loadUnitId,
  String goodName,
  String uom,
  String productionDate,
  double expected,
  double? fact,
  bool problem,
});

/// Объект области для выбора: id для сервера, подпись для человека, глубина - у дерева групп.
typedef ScopeObject = ({String id, String label, int depth});

/// Пересчёты в портале (P10-05): список, ход, заведение по любой области и закрытие. Всё -
/// старшему смены; пока право «заводить пересчёт» у admin.
///
/// Контракт для экранов портала (`dev.md §2`, ADHOC-71); реализация - `StocktakesRepositoryImpl` в `data`.
abstract interface class StocktakesRepository {
  /// Пересчёты: `open`, `closed` или все.
  Future<Either<Failure, List<PortalStocktake>>> list({String? status});

  /// Ячейки пересчёта со статусами.
  Future<Either<Failure, List<PortalStocktakeCell>>> cells(String id);

  /// Что ожидалось и что посчитано по ячейкам (только портал: на ТСД счёт слепой).
  Future<Either<Failure, List<PortalStocktakeLine>>> lines(String id);

  /// Завести пересчёт; ответ - номер и сколько ячеек дала область.
  Future<Either<Failure, ({int number, int cells})>> create({
    required String warehouseId,
    required String scopeKind,
    required List<String> objectIds,
  });

  /// Закрыть пересчёт; [force] - с неподсчитанными ячейками.
  Future<Either<Failure, void>> close(String id, {required bool force});

  /// Склад портала - склад ячеек справочника: пилот - один склад. `null` - ячеек нет.
  Future<Either<Failure, String?>> warehouseId();

  /// Ячейки по адресу (поиск на сервере), без ячейки приёмки - она в пересчёт не входит.
  Future<Either<Failure, List<ScopeObject>>> searchCells(String query);

  /// Товары по коду или наименованию (поиск на сервере).
  Future<Either<Failure, List<ScopeObject>>> searchGoods(String query);

  /// Дерево групп номенклатуры плоским списком в порядке обхода (`flattenGroups` в `data`).
  Future<Either<Failure, List<ScopeObject>>> groups();

  /// Поставщики.
  Future<Either<Failure, List<ScopeObject>>> suppliers();

  /// Внутренние склады, которые можно выбрать областью: активные, не системные.
  Future<Either<Failure, List<ScopeObject>>> internalWarehouses();
}
