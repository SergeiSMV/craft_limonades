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
    test('успех → парсит документы', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.stockEntrySessions}': (_) => ResponseBody.fromString(
              '[{"id":"s1","warehouse_code":"SHB","warehouse_name":"Шабулина","closed_at":"2026-08-13T21:00:00Z","lines_count":5}]',
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
      expect(docs.first.id, 's1');
      expect(docs.first.warehouseCode, 'SHB');
      expect(docs.first.linesCount, 5);
      expect(docs.first.closedAt.isUtc, isTrue);
    });

    test('401 → Failure.server(401)', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.stockEntrySessions}': (_) => ResponseBody.fromString('{"error":"x"}', 401, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await InventoryRepository(dio).listDocuments();
      expect(res.isLeft, isTrue);
      expect(res.left, isA<ServerFailure>());
    });
  });

  group('downloadReport', () {
    test('успех → байты; GET report.xlsx с responseType bytes', () async {
      final xlsx = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04]); // PK..
      final adapter = RecordingAdapter({
        'GET ${ApiConst.stockEntryReport("s1")}': (_) => ResponseBody.fromBytes(xlsx, 200, headers: {
          Headers.contentTypeHeader: ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
        }),
      });
      dio.httpClientAdapter = adapter;

      final res = await InventoryRepository(dio).downloadReport('s1');
      expect(res.isRight, isTrue);
      expect(res.right, equals(xlsx));
      final req = adapter.requests.single;
      expect(req.path, ApiConst.stockEntryReport('s1'));
      expect(req.responseType, ResponseType.bytes);
    });

    test('маршрут отчёта — без ведущего слэша', () {
      expect(ApiConst.stockEntryReport('s1'), 'stock-entry/sessions/s1/report.xlsx');
      expect(ApiConst.stockEntryReport('s1').startsWith('/'), isFalse);
    });
  });
}
