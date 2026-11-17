import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/dio_failure.dart';
import '../../core/error/failure.dart';

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
@lazySingleton
class StocktakesRepository {
  StocktakesRepository(this._dio);

  final Dio _dio;

  /// Пересчёты: `open`, `closed` или все.
  Future<Either<Failure, List<PortalStocktake>>> list({String? status}) =>
      _call(() async {
        final resp = await _dio.get<List<dynamic>>(
          ApiConst.stocktakes,
          queryParameters: status == null ? null : {'status': status},
        );
        return [
          for (final e in resp.data ?? const [])
            PortalStocktake.fromJson(e as Map<String, dynamic>),
        ];
      });

  /// Ячейки пересчёта со статусами.
  Future<Either<Failure, List<PortalStocktakeCell>>> cells(String id) =>
      _call(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          ApiConst.stocktakeById(id),
        );
        return [
          for (final e in resp.data?['cells'] as List? ?? const [])
            (
              address: (e as Map<String, dynamic>)['address'] as String? ?? '',
              status: e['status'] as String? ?? '',
              takenBy: e['taken_by'] as String? ?? '',
            ),
        ];
      });

  /// Что ожидалось и что посчитано по ячейкам (только портал: на ТСД счёт слепой).
  Future<Either<Failure, List<PortalStocktakeLine>>> lines(String id) =>
      _call(() async {
        final resp = await _dio.get<List<dynamic>>(ApiConst.stocktakeLines(id));
        double? qty(Object? v) => v == null ? null : double.tryParse('$v');
        return [
          for (final e in resp.data ?? const [])
            (
              cell: (e as Map<String, dynamic>)['cell'] as String? ?? '',
              loadUnitId: e['load_unit_id'] as String? ?? '',
              goodName: e['good_name'] as String? ?? '',
              uom: e['uom'] as String? ?? '',
              productionDate: e['production_date'] as String? ?? '',
              expected: qty(e['expected']) ?? 0,
              fact: qty(e['fact']),
              problem: e['problem'] as bool? ?? false,
            ),
        ];
      });

  /// Завести пересчёт; ответ - номер и сколько ячеек дала область.
  Future<Either<Failure, ({int number, int cells})>> create({
    required String warehouseId,
    required String scopeKind,
    required List<String> objectIds,
  }) => _call(() async {
    final resp = await _dio.post<Map<String, dynamic>>(
      ApiConst.stocktakes,
      data: {
        'warehouse_id': warehouseId,
        'scope_kind': scopeKind,
        'object_ids': objectIds,
      },
    );
    final j = resp.data ?? const {};
    return (
      number: (j['number'] as num?)?.toInt() ?? 0,
      cells: (j['cells'] as num?)?.toInt() ?? 0,
    );
  });

  /// Закрыть пересчёт; [force] - с неподсчитанными ячейками.
  Future<Either<Failure, void>> close(String id, {required bool force}) =>
      _call(() async {
        await _dio.post<void>(
          ApiConst.stocktakeClose(id),
          data: {'force': force},
        );
      });

  /// Склад портала - склад ячеек справочника: пилот - один склад. `null` - ячеек нет.
  Future<Either<Failure, String?>> warehouseId() => _call(() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      ApiConst.cells,
      queryParameters: {'limit': 1},
    );
    final items = resp.data?['items'] as List? ?? const [];
    return items.isEmpty
        ? null
        : (items.first as Map<String, dynamic>)['warehouse_id'] as String?;
  });

  /// Ячейки по адресу (поиск на сервере), без ячейки приёмки - она в пересчёт не входит.
  Future<Either<Failure, List<ScopeObject>>> searchCells(String query) =>
      _call(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          ApiConst.cells,
          queryParameters: {'q': query, 'limit': 50},
        );
        return [
          for (final e in resp.data?['items'] as List? ?? const [])
            if ((e as Map<String, dynamic>)['is_default'] != true)
              (id: e['id'] as String, label: e['address'] as String, depth: 0),
        ];
      });

  /// Товары по коду или наименованию (поиск на сервере).
  Future<Either<Failure, List<ScopeObject>>> searchGoods(String query) =>
      _call(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          ApiConst.goods,
          queryParameters: {'q': query, 'limit': 50},
        );
        return [
          for (final e in resp.data?['items'] as List? ?? const [])
            (
              id: (e as Map<String, dynamic>)['id'] as String,
              label: [
                if ((e['code'] as String?)?.isNotEmpty ?? false) e['code'],
                e['name'],
              ].join(' · '),
              depth: 0,
            ),
        ];
      });

  /// Дерево групп номенклатуры плоским списком в порядке обхода (см. [flattenGroups]).
  Future<Either<Failure, List<ScopeObject>>> groups() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.nomenclatureGroups);
    return flattenGroups([
      for (final e in resp.data ?? const []) e as Map<String, dynamic>,
    ]);
  });

  /// Поставщики.
  Future<Either<Failure, List<ScopeObject>>> suppliers() => _call(() async {
    final resp = await _dio.get<List<dynamic>>(ApiConst.suppliers);
    return [
      for (final e in resp.data ?? const [])
        (
          id: (e as Map<String, dynamic>)['id'] as String,
          label: e['name'] as String? ?? '',
          depth: 0,
        ),
    ];
  });

  /// Внутренние склады, которые можно выбрать областью: активные, не системные.
  Future<Either<Failure, List<ScopeObject>>> internalWarehouses() =>
      _call(() async {
        final resp = await _dio.get<List<dynamic>>(ApiConst.internalWarehouses);
        return [
          for (final e in resp.data ?? const [])
            if ((e as Map<String, dynamic>)['is_active'] != false &&
                ((e['system_role'] as String?) ?? '').isEmpty)
              (
                id: e['id'] as String,
                label: e['name'] as String? ?? '',
                depth: 0,
              ),
        ];
      });

  Future<Either<Failure, T>> _call<T>(Future<T> Function() fn) async {
    try {
      return Right(await fn());
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}

/// Дерево групп номенклатуры плоским списком: родитель, затем его поддерево, на каждом уровне -
/// по имени; глубина - уровень в дереве. Матрица - узел этого дерева.
List<ScopeObject> flattenGroups(List<Map<String, dynamic>> all) {
  final children = <String?, List<Map<String, dynamic>>>{};
  for (final g in all) {
    children.putIfAbsent(g['parent_id'] as String?, () => []).add(g);
  }
  for (final list in children.values) {
    list.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  }
  final out = <ScopeObject>[];
  void walk(String? parent, int depth) {
    for (final g in children[parent] ?? const <Map<String, dynamic>>[]) {
      out.add((
        id: g['id'] as String,
        label: g['name'] as String,
        depth: depth,
      ));
      walk(g['id'] as String, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}
