import 'dart:typed_data';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/data/cells_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  group('downloadCellLabels', () {
    test('успех → байты PDF; GET cells/labels.pdf?warehouse=SHB, responseType bytes', () async {
      final pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D]); // %PDF-
      final adapter = RecordingAdapter({
        'GET ${ApiConst.cellLabelsPdf}': (_) => ResponseBody.fromBytes(
              pdf,
              200,
              headers: {
                Headers.contentTypeHeader: ['application/pdf'],
              },
            ),
      });
      dio.httpClientAdapter = adapter;
      final repo = CellsRepository(dio);

      final result = await repo.downloadCellLabels();

      expect(result.isRight, isTrue);
      expect(result.right, equals(pdf));
      final req = adapter.requests.single;
      expect(req.path, ApiConst.cellLabelsPdf);
      expect(req.queryParameters['warehouse'], 'SHB');
      expect(req.responseType, ResponseType.bytes);
    });

    test('404 (склад не найден) → ServerFailure(404)', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.cellLabelsPdf}': (_) => ResponseBody.fromString(
              '{"error":"склад не найден"}',
              404,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ),
      });
      final repo = CellsRepository(dio);

      final result = await repo.downloadCellLabels();

      expect(result.isLeft, isTrue);
      expect(result.left, isA<ServerFailure>());
      expect((result.left as ServerFailure).statusCode, 404);
    });

    test('маршрут этикеток — без ведущего слэша', () {
      expect(ApiConst.cellLabelsPdf, 'cells/labels.pdf');
      expect(ApiConst.cellLabelsPdf.startsWith('/'), isFalse);
    });
  });
}
