import 'dart:typed_data';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/data/inventory_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  group('listDocuments', () {
    test('успех → парсит документы со статусом', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString(
              '[{"id":"d1","kind":"stock_entry","warehouse_code":"SHB","warehouse_name":"Шабулина",'
              '"created_at":"2026-08-13T21:00:00Z","lines_count":5,'
              '"status":"downloaded","downloaded_at":"2026-08-14T07:00:00Z","done_at":null}]',
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ),
      });
      final repo = InventoryRepository(dio);

      final res = await repo.listDocuments();
      expect(res.isRight, isTrue);
      final docs = res.right;
      expect(docs, hasLength(1));
      expect(docs.first.id, 'd1');
      expect(docs.first.warehouseCode, 'SHB');
      expect(docs.first.linesCount, 5);
      expect(docs.first.createdAt.isUtc, isTrue);
      expect(docs.first.status, DocStatus.downloaded);
    });

    test('незнакомый статус → показываем как новый, а не прячем в выполненных', () {
      expect(DocStatus.parse('archived'), DocStatus.isNew);
      expect(DocStatus.parse(null), DocStatus.isNew);
      expect(DocStatus.parse('done'), DocStatus.done);
    });

    test('401 → Failure.server(401)', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.documents}': (_) => ResponseBody.fromString('{"error":"x"}', 401, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await InventoryRepository(dio).listDocuments();
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  group('downloadReport', () {
    test('успех → байты; GET file.xlsx с responseType bytes', () async {
      final xlsx = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04]); // PK..
      final adapter = RecordingAdapter({
        'GET ${ApiConst.documentFile("d1")}': (_) => ResponseBody.fromBytes(xlsx, 200, headers: {
          Headers.contentTypeHeader: ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
        }),
      });
      dio.httpClientAdapter = adapter;

      final res = await InventoryRepository(dio).downloadReport('d1');
      expect(res.isRight, isTrue);
      expect(res.right, equals(xlsx));
      final req = adapter.requests.single;
      expect(req.path, ApiConst.documentFile('d1'));
      expect(req.responseType, ResponseType.bytes);
    });
  });

  group('markDone', () {
    test('успех → Right; POST на documents/{id}/done', () async {
      final adapter = RecordingAdapter({
        'POST ${ApiConst.documentDone("d1")}': (_) => ResponseBody.fromString('', 204),
      });
      dio.httpClientAdapter = adapter;

      final res = await InventoryRepository(dio).markDone('d1');
      expect(res.isRight, isTrue);
      expect(adapter.requests.single.path, ApiConst.documentDone('d1'));
    });

    test('404 → Failure.server', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'POST ${ApiConst.documentDone("d1")}': (_) => ResponseBody.fromString('{"error":"нет"}', 404, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await InventoryRepository(dio).markDone('d1');
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  test('маршруты документов — без ведущего слэша', () {
    expect(ApiConst.documents, 'documents');
    expect(ApiConst.documentFile('d1'), 'documents/d1/file.xlsx');
    expect(ApiConst.documentDone('d1'), 'documents/d1/done');
    expect(ApiConst.documentFile('d1').startsWith('/'), isFalse);
    expect(ApiConst.documentDone('d1').startsWith('/'), isFalse);
  });
}
