import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/data/picking_orders_repository_impl.dart';
import 'package:craft_wms/portal/domain/picking/picking_order.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

ResponseBody _json(String body, int status) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

const _order =
    '"id":"o1","number":9,"registry_date":"2026-11-09","invoice_number":"20961",'
    '"order_number":"15512","order_date":"2026-11-07","direction":"Рязань","client":"ИП Суслова",'
    '"address":"ул. Ленина, 1","status":"in_progress","is_partial":false,"has_unknown":false,'
    '"deleted":false,"changed_after_shipment":false,"assignee_name":"Анна",'
    '"taken_at":"2026-11-08T07:00:00Z","picked_by_name":"","picked_at":null,"shipped_at":null,'
    '"lines":1,"plan_qty":3,"fact_qty":"1.5","boxes":1';

/// P8-03: раздел «Сборка-отгрузка» портала - разбор списка и деталей, дата в запросе, отказ
/// снятия текстом сервера.
void main() {
  late Dio dio;
  late RecordingAdapter adapter;

  setUp(() => dio = Dio(BaseOptions(baseUrl: 'https://api.test')));

  test('список даты: статус, исполнитель, факт строкой decimal', () async {
    adapter = RecordingAdapter({
      'GET ${ApiConst.pickingPortalOrders}': (_) => _json('[{$_order}]', 200),
    });
    dio.httpClientAdapter = adapter;
    final res = await PickingOrdersRepositoryImpl(
      dio,
    ).orders(DateTime(2026, 11, 9));
    expect(res.isRight, isTrue);
    final o = res.right.single;
    expect(o.status, PickingStatus.inProgress);
    expect(o.releasable, isTrue);
    expect(o.assigneeName, 'Анна');
    expect(o.factQty, 1.5);
    expect(o.orderDate, DateTime(2026, 11, 7));
    expect(adapter.requests.single.queryParameters['date'], '2026-11-09');
  });

  test('детали: строка с фактом по партии и марками, короб, правка', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'GET ${ApiConst.pickingPortalOrder('o1')}': (_) => _json(
        '{$_order,"items":[{"id":"l1","line_no":1,"good_code":"00000016147",'
        '"good_name":"Лимонад","uom":"шт","cz_marked":true,"batch_date":"2026-10-01",'
        '"registry_cell":"A-1","cell_address":"A-1","plan_qty":3,"fact_qty":"1",'
        '"removed":false,"shortage":true,"facts":[{"batch_date":"2026-10-01",'
        '"cell_address":"A-1","box_seq":1,"qty":"1","state":"picking","picked_by":"Анна",'
        '"picked_at":"2026-11-08T07:10:00Z","marks":["0104600000000017215abc"]}]}],'
        '"box_list":[{"seq":1,"shipped_at":null}],"changes":[{"kind":"qty_changed",'
        '"good_code":"00000016147","good_name":"Лимонад","batch_date":null,"old_qty":2,'
        '"new_qty":3,"order_status":"new","at":"2026-11-08T06:00:00Z"}]}',
        200,
      ),
    });
    final res = await PickingOrdersRepositoryImpl(dio).order('o1');
    expect(res.isRight, isTrue);
    final d = res.right;
    final line = d.lines.single;
    expect(line.czMarked, isTrue);
    expect(line.shortage, isTrue);
    expect(line.marks, ['0104600000000017215abc']);
    expect(line.facts.single.inBox, isFalse);
    expect(d.boxes.single.seq, 1);
    expect(d.changes.single.oldQty, 2);
    expect(d.changes.single.orderStatus, PickingStatus.newOrder);
  });

  test('снятие собранного - отказ текстом сервера', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'POST ${ApiConst.pickingPortalRelease('o1')}': (_) =>
          _json('{"error":"заказ уже собран или отгружен"}', 409),
    });
    final res = await PickingOrdersRepositoryImpl(dio).release('o1');
    expect(res.isLeft, isTrue);
    final f = res.left;
    expect(f, isA<ServerFailure>());
    expect((f as ServerFailure).message, 'заказ уже собран или отгружен');
  });
}
