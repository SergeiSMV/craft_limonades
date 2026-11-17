import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/sync/sync_engine.dart';
import 'package:craft_wms/features/stock_entry/data/stock_entry_repository_impl.dart';
import 'package:craft_wms/features/stock_entry/domain/stock_entry_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_dio_adapter.dart';

class _MockEngine extends Mock implements SyncEngine {}

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  StockEntryRepository repoWith(
    Map<String, ResponseBody Function(RequestOptions)> responses,
  ) {
    dio.httpClientAdapter = RecordingAdapter(responses);
    return StockEntryRepositoryImpl(dio, _MockEngine());
  }

  test('startSession → session_id', () async {
    final repo = repoWith({
      'POST ${ApiConst.stockEntrySessions}': (_) =>
          jsonResponse({'session_id': 'sess-1'}, 201),
    });
    final res = await repo.startSession('w1');
    expect(res.isRight, isTrue);
    expect(res.right, 'sess-1');
  });

  test('checkpoint → 200, тело уходит как есть', () async {
    final adapter = RecordingAdapter({
      'POST ${ApiConst.stockEntryCells("sess-1")}': (_) =>
          jsonResponse({'accepted': 1}, 200),
    });
    dio.httpClientAdapter = adapter;
    final repo = StockEntryRepositoryImpl(dio, _MockEngine());

    final res = await repo.checkpoint(
      sessionId: 'sess-1',
      body: {
        'cell_id': 'c1',
        'lines': [
          {'good_id': 'g1', 'production_date': '15-01-2026', 'qty': 10},
        ],
      },
    );
    expect(res.isRight, isTrue);
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['cell_id'], 'c1');
    expect((body['lines'] as List).single['production_date'], '15-01-2026');
  });

  // Отказ строк (ADHOC-46): сервер отвечает 422 с текстом - он доходит до экрана как есть.
  test('checkpoint → 422: текст отказа в ServerFailure', () async {
    final repo = repoWith({
      'POST ${ApiConst.stockEntryCells("sess-1")}': (_) =>
          jsonResponse({'error': 'Отклонено строк: 1 из 2'}, 422),
    });
    final res = await repo.checkpoint(sessionId: 'sess-1', body: const {});
    expect(res.isLeft, isTrue);
    expect(res.left, const Failure.server(422, 'Отклонено строк: 1 из 2'));
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
