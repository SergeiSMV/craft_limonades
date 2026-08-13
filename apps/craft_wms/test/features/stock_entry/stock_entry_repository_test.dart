import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/features/stock_entry/data/stock_entry_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  StockEntryRepository repoWith(Map<String, ResponseBody Function(RequestOptions)> responses) {
    dio.httpClientAdapter = RecordingAdapter(responses);
    return StockEntryRepository(dio);
  }

  group('resolveGoodByBarcode', () {
    test('200 → товар', () async {
      final repo = repoWith({
        'GET ${ApiConst.barcodeByCode("460")}': (_) => jsonResponse({
              'id': 'g1',
              'name': 'Чипсы',
              'uom': 'шт',
              'is_active': true,
            }, 200),
      });
      final res = await repo.resolveGoodByBarcode('460');
      expect(res.isRight, isTrue);
      expect(res.right!.id, 'g1');
    });

    test('404 → Right(null) (ШК не привязан, не ошибка)', () async {
      final repo = repoWith({
        'GET ${ApiConst.barcodeByCode("460")}': (_) =>
            ResponseBody.fromString('{"error":"нет"}', 404, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      });
      final res = await repo.resolveGoodByBarcode('460');
      expect(res.isRight, isTrue);
      expect(res.right, isNull);
    });
  });

  test('startSession → session_id', () async {
    final repo = repoWith({
      'POST ${ApiConst.stockEntrySessions}': (_) => jsonResponse({'session_id': 'sess-1'}, 201),
    });
    final res = await repo.startSession('w1');
    expect(res.isRight, isTrue);
    expect(res.right, 'sess-1');
  });

  test('checkpoint → 200, тело содержит cell_id/lines/new_barcodes', () async {
    final adapter = RecordingAdapter({
      'POST ${ApiConst.stockEntryCells("sess-1")}': (_) => jsonResponse({'accepted': 1}, 200),
    });
    dio.httpClientAdapter = adapter;
    final repo = StockEntryRepository(dio);

    final res = await repo.checkpoint(
      sessionId: 'sess-1',
      cellId: 'c1',
      lines: [
        {'good_id': 'g1', 'production_date': '15-01-2026', 'qty': 10},
      ],
      newBarcodes: [
        {'good_id': 'g1', 'barcode': '460', 'symbology': 'ean13'},
      ],
    );
    expect(res.isRight, isTrue);
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['cell_id'], 'c1');
    expect((body['lines'] as List).single['production_date'], '15-01-2026');
    expect((body['new_barcodes'] as List).single['barcode'], '460');
  });

  test('finalize → written', () async {
    final repo = repoWith({
      'POST ${ApiConst.stockEntryFinalize("sess-1")}': (_) =>
          jsonResponse({'written': 3, 'status': 'closed'}, 200),
    });
    final res = await repo.finalize('sess-1');
    expect(res.isRight, isTrue);
    expect(res.right, 3);
  });
}
