import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../../core/constants/api_constants.dart';
import '../../core/error/failure.dart';
import '../domain/picking/picking_order.dart';
import 'documents_repository.dart';

/// Раздел «Сборка-отгрузка» портала поверх API P8-03. Слой data: HTTP и разбор ответа в
/// сущности домена; отказ по существу сервер объясняет текстом в поле `error` - он приезжает в
/// `ServerFailure.message`.
@LazySingleton(as: PickingOrdersRepository)
class PickingOrdersRepositoryImpl implements PickingOrdersRepository {
  PickingOrdersRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Either<Failure, List<PickingOrderSummary>>> orders(DateTime date) =>
      _call(() async {
        final resp = await _dio.get<List<dynamic>>(
          ApiConst.pickingPortalOrders,
          queryParameters: {'date': isoDate(date)},
        );
        return [
          for (final o in resp.data ?? const [])
            _summary(o as Map<String, dynamic>),
        ];
      });

  @override
  Future<Either<Failure, PickingOrderDetail>> order(String id) =>
      _call(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          ApiConst.pickingPortalOrder(id),
        );
        return _detail(resp.data!);
      });

  @override
  Future<Either<Failure, void>> release(String id) =>
      _call(() => _dio.post<void>(ApiConst.pickingPortalRelease(id)));

  @override
  Future<Either<Failure, PickingExport>> export(DateTime date) =>
      _call(() async {
        final resp = await _dio.get<List<int>>(
          ApiConst.pickingPortalExport,
          queryParameters: {'date': isoDate(date)},
          options: Options(responseType: ResponseType.bytes),
        );
        return (
          bytes: Uint8List.fromList(resp.data!),
          filename: filenameFromDisposition(
            resp.headers.value('content-disposition'),
          ),
        );
      });

  Future<Either<Failure, T>> _call<T>(Future<T> Function() run) async {
    try {
      return Right(await run());
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == null) return const Left(Failure.network());
      final data = e.response?.data;
      final message = data is Map ? data['error'] as String? : null;
      return Left(Failure.server(code, message));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }
}

/// Дата для запроса: «ГГГГ-ММ-ДД» по календарю оператора.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);

/// Количество: сервер шлёт decimal строкой («2.5»), бывает и числом.
double _qty(Object? v) => double.tryParse('$v') ?? 0;

PickingOrderSummary _summary(Map<String, dynamic> j) => PickingOrderSummary(
  id: j['id'] as String,
  number: j['number'] as int,
  registryDate: DateTime.parse(j['registry_date'] as String),
  invoiceNumber: j['invoice_number'] as String,
  orderNumber: j['order_number'] as String,
  orderDate: _date(j['order_date']),
  direction: j['direction'] as String,
  client: j['client'] as String,
  address: j['address'] as String,
  status: pickingStatusOf(j['status'] as String),
  isPartial: j['is_partial'] as bool,
  hasUnknown: j['has_unknown'] as bool,
  deleted: j['deleted'] as bool,
  changedAfterShipment: j['changed_after_shipment'] as bool,
  assigneeName: j['assignee_name'] as String,
  takenAt: _date(j['taken_at']),
  pickedByName: j['picked_by_name'] as String,
  pickedAt: _date(j['picked_at']),
  shippedAt: _date(j['shipped_at']),
  lines: j['lines'] as int,
  planQty: j['plan_qty'] as int,
  factQty: _qty(j['fact_qty']),
  boxes: j['boxes'] as int,
  returnLeft: _qty(j['return_left']),
  outOfSync: j['out_of_sync'] as bool? ?? false,
);

PickingOrderDetail _detail(Map<String, dynamic> j) => PickingOrderDetail(
  order: _summary(j),
  lines: [for (final l in j['items'] as List) _line(l as Map<String, dynamic>)],
  boxes: [
    for (final b in j['box_list'] as List)
      PickingBoxInfo(
        seq: (b as Map<String, dynamic>)['seq'] as int,
        shippedAt: _date(b['shipped_at']),
      ),
  ],
  changes: [
    for (final c in j['changes'] as List) _change(c as Map<String, dynamic>),
  ],
  events: [
    for (final e in j['events'] as List? ?? const [])
      _event(e as Map<String, dynamic>),
  ],
);

PickingOrderEvent _event(Map<String, dynamic> j) => PickingOrderEvent(
  kind: j['kind'] as String,
  userName: j['user_name'] as String,
  prevName: j['prev_name'] as String,
  boxes: j['boxes'] as int?,
  qty: j['qty'] == null ? null : _qty(j['qty']),
  at: DateTime.parse(j['at'] as String),
);

PickingOrderLine _line(Map<String, dynamic> j) => PickingOrderLine(
  lineNo: j['line_no'] as int,
  goodCode: j['good_code'] as String,
  goodName: j['good_name'] as String,
  uom: j['uom'] as String,
  czMarked: j['cz_marked'] as bool,
  batchDate: _date(j['batch_date']),
  registryCell: j['registry_cell'] as String,
  cellAddress: j['cell_address'] as String,
  planQty: j['plan_qty'] as int,
  factQty: _qty(j['fact_qty']),
  removed: j['removed'] as bool,
  shortage: j['shortage'] as bool,
  facts: [for (final f in j['facts'] as List) _fact(f as Map<String, dynamic>)],
);

PickingFact _fact(Map<String, dynamic> j) => PickingFact(
  batchDate: DateTime.parse(j['batch_date'] as String),
  cellAddress: j['cell_address'] as String,
  boxSeq: j['box_seq'] as int,
  qty: _qty(j['qty']),
  inBox: j['state'] == 'moved',
  pickedBy: j['picked_by'] as String,
  pickedAt: DateTime.parse(j['picked_at'] as String),
  marks: [for (final m in j['marks'] as List) m as String],
);

PickingOrderChange _change(Map<String, dynamic> j) => PickingOrderChange(
  kind: j['kind'] as String,
  goodCode: j['good_code'] as String,
  goodName: j['good_name'] as String,
  batchDate: _date(j['batch_date']),
  oldQty: j['old_qty'] as int?,
  newQty: j['new_qty'] as int?,
  orderStatus: pickingStatusOf(j['order_status'] as String),
  at: DateTime.parse(j['at'] as String),
  reason: j['reason'] as String? ?? '',
);
