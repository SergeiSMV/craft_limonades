import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/error/dio_failure.dart';
import '../../../core/error/failure.dart';
import '../../../core/outbox/outbox_operation.dart';
import '../../../core/outbox/outbox_repository.dart';
import '../../../core/warehouse/internal_warehouses.dart';
import '../../contents/data/contents_cache.dart';
import '../../contents/domain/contents_entities.dart';
import '../../stock/data/catalog_cache.dart';
import '../domain/problem_records.dart';

/// Проблемы склада для ТСД: лента решённых (`GET /problems/resolved`, ADHOC-34) и открытые
/// (`GET /problems/current` + своя очередь, ADHOC-35). Списки с сервера не кэшируются, как
/// и «Завершённые» задания и перемещения; свои неотправленные видны и без связи.
@LazySingleton(as: ProblemRecordsRepository)
class ProblemRecordsRepositoryImpl implements ProblemRecordsRepository {
  ProblemRecordsRepositoryImpl(
    this._dio,
    this._outbox,
    this._catalog,
    this._contents,
    this._warehouses,
  );

  final Dio _dio;
  final OutboxRepository _outbox;
  final CatalogCache _catalog;
  final ContentsCache _contents;
  final InternalWarehouses _warehouses;

  /// Сколько операций очереди просматривать: неотправленных проблем на терминале единицы.
  static const _queueLimit = 1000;

  @override
  Future<Either<Failure, List<ProblemRecord>>> resolved({
    required ResolvedProblemsQuery query,
    ProblemRecord? after,
    int limit = 30,
  }) => _list(ApiConst.problemsResolved, {
    if (query.from != null) 'from': _day(query.from!),
    if (query.to != null) 'to': _day(query.to!),
    if (after != null && after.resolvedAt != null)
      'before_resolved_at': after.resolvedAt,
    if (after != null) 'before_id': after.id,
    'limit': limit,
  });

  @override
  Future<CurrentProblems> current() async {
    final res = await _list(ApiConst.problemsCurrent, null);
    final open = res.isRight ? res.right : const <ProblemRecord>[];
    // Своя проблема, которую сервер уже провёл (ответ на отправку не дошёл), — серверной.
    final known = {for (final p in open) p.id};
    final pending = [
      for (final p in await _pending())
        if (!known.contains(p.id)) p,
    ];
    return CurrentProblems(
      pending: pending,
      open: open,
      failure: res.isLeft ? res.left : null,
    );
  }

  /// Свои неотправленные проблемы из очереди, свежие первыми. Подписи — из справочников
  /// терминала, место короба — из снимка склада: в теле операции у короба ячейки нет.
  Future<List<ProblemRecord>> _pending() async {
    final ops = [
      for (final op in await _outbox.pending(limit: _queueLimit))
        if (op.kind == OutboxKind.problemSubmit) op,
    ];
    if (ops.isEmpty) return const [];
    final cells = {for (final c in await _catalog.cells()) c.id: c.address};
    final warehouses = await _warehouses.all();
    String warehouseName(String? id) =>
        warehouses
            .where((w) => id == null ? w.isDefault : w.id == id)
            .firstOrNull
            ?.name ??
        '';
    final boxIds = [
      for (final op in ops)
        ?(op.payload['load_unit_id'] ?? op.payload['from_load_unit_id'])
            as String?,
    ];
    final boxes = await _contents.loadUnits(boxIds);

    final out = <ProblemRecord>[];
    for (final op in ops.reversed) {
      final p = op.payload;
      final boxId = p['load_unit_id'] as String?;
      final box = boxes[boxId ?? p['from_load_unit_id']];
      final cellId = p['cell_id'] as String? ?? box?.cellId;
      final cell = cells[cellId] ?? '';
      final items = <ProblemRecordItem>[];
      if (boxId != null) {
        for (final l in box?.lines ?? const <ContentLine>[]) {
          final g = await _catalog.goodById(l.goodId);
          items.add(
            ProblemRecordItem(
              goodName: g?.name ?? '',
              goodCode: g?.code,
              productionDate: _iso(l.productionDate),
              qty: '${l.qty}',
              cellAddress: cell,
            ),
          );
        }
      } else if (p['good_id'] case final String goodId) {
        final g = await _catalog.goodById(goodId);
        items.add(
          ProblemRecordItem(
            goodName: g?.name ?? '',
            goodCode: g?.code,
            productionDate: _iso(p['production_date'] as String? ?? ''),
            qty: '${p['qty']}',
            cellAddress: cell,
          ),
        );
      }
      out.add(
        ProblemRecord(
          id: p['problem_id'] as String? ?? op.operationId,
          createdAt: op.createdAt,
          createdBy: '',
          cellAddress: cell,
          loadUnitId: boxId,
          reason: p['reason'] as String? ?? '',
          comment: p['comment'] as String? ?? '',
          mark: p['mark'] as String?,
          // Склад, откуда помечено: у короба — его склад, у товара — склад строки.
          fromWarehouse: warehouseName(
            boxId != null
                ? box?.internalWarehouseId
                : p['internal_warehouse_id'] as String?,
          ),
          toWarehouse: warehouseName(p['to_internal_warehouse_id'] as String?),
          items: items,
          pending: true,
        ),
      );
    }
    return out;
  }

  Future<Either<Failure, List<ProblemRecord>>> _list(
    String path,
    Map<String, dynamic>? query,
  ) async {
    try {
      final resp = await _dio.get<List<dynamic>>(path, queryParameters: query);
      return Right([
        for (final e in resp.data ?? const [])
          problemRecordFromJson(e as Map<String, dynamic>),
      ]);
    } on DioException catch (e) {
      return Left(mapDioError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// День фильтра в виде YYYY-MM-DD — сервер толкует его по времени склада.
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Дата партии из очереди (DD-MM-YYYY) — в вид сервера (YYYY-MM-DD): записи показываются
  /// одинаково, откуда бы ни пришли.
  static String _iso(String transport) {
    final p = transport.split('-');
    return p.length == 3 && p[2].length == 4
        ? '${p[2]}-${p[1]}-${p[0]}'
        : transport;
  }
}

/// Проблема из ответа сервера — открытая или решённая. Пустые строки необязательных полей — `null`:
/// сервер опускает их или отдаёт пустыми.
ProblemRecord problemRecordFromJson(Map<String, dynamic> j) {
  String? opt(String key) {
    final v = j[key] as String?;
    return v == null || v.isEmpty ? null : v;
  }

  final task = j['return_task_number'] as int?;
  return ProblemRecord(
    id: j['id'] as String,
    number: (j['number'] as num?)?.toInt(),
    createdAt: DateTime.parse(j['created_at'] as String),
    createdBy: j['created_by'] as String? ?? '',
    cellAddress: j['cell_address'] as String? ?? '',
    loadUnitId: opt('load_unit_id'),
    reason: j['reason'] as String? ?? '',
    comment: j['comment'] as String? ?? '',
    mark: opt('mark'),
    fromWarehouse: j['from_warehouse'] as String? ?? '',
    toWarehouse: j['to_warehouse'] as String? ?? '',
    items: [
      for (final e in j['items'] as List? ?? const [])
        _item(e as Map<String, dynamic>),
    ],
    decision: j['decision'] as String? ?? '',
    docNumber: opt('doc_number'),
    docDate: opt('doc_date'),
    supplierName: opt('supplier_name'),
    returnTaskNumber: task == null || task == 0 ? null : task,
    resolvedBy: j['resolved_by'] as String? ?? '',
    resolvedAt: opt('resolved_at'),
    shippedBy: opt('shipped_by'),
    shippedAt: switch (opt('shipped_at')) {
      final v? => DateTime.parse(v),
      null => null,
    },
    shipmentNumber: (j['shipment_number'] as num?)?.toInt(),
    photos: [for (final id in j['photos'] as List? ?? const []) id as String],
  );
}

ProblemRecordItem _item(Map<String, dynamic> e) {
  final code = e['good_code'] as String? ?? '';
  return ProblemRecordItem(
    goodName: e['good_name'] as String? ?? '',
    goodCode: code.isEmpty ? null : code,
    productionDate: e['production_date'] as String? ?? '',
    qty: e['qty'] as String? ?? '0',
    cellAddress: e['cell_address'] as String? ?? '',
  );
}
