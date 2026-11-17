import 'package:craft_wms/features/stocktake/data/cell_count_check_impl.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_dio_adapter.dart';

/// ADHOC-48: проверка ячейки на подсчёт перед движением - ответ сервера, подтверждённый
/// подсчёт не спрашивается снова, без связи - как будто подсчёта нет.
void main() {
  const path = 'GET cells/c1/stocktake-count';
  const counting = {
    'counting': {
      'stocktake_number': 12,
      'address': 'M1-1-1-1',
      'counted_by': 'Иванов И.',
      'started_at': '2026-10-26T10:00:00Z',
    },
  };

  CellCountCheckImpl checkWith(ResponseBody Function(RequestOptions) answer) {
    final dio = Dio()..httpClientAdapter = RecordingAdapter({path: answer});
    return CellCountCheckImpl(dio);
  }

  test('ячейка на подсчёте - кто считает и какой пересчёт', () async {
    final check = checkWith((_) => jsonResponse(counting, 200));
    final count = await check.counting('c1');
    expect(count?.stocktakeNumber, 12);
    expect(count?.address, 'M1-1-1-1');
    expect(count?.countedBy, 'Иванов И.');
  });

  test('подсчёта нет - null', () async {
    final check = checkWith((_) => jsonResponse({'counting': null}, 200));
    expect(await check.counting('c1'), isNull);
  });

  test(
    'подтверждённый подсчёт второй раз не спрашивается, новый - да',
    () async {
      var startedAt = '2026-10-26T10:00:00Z';
      final check = checkWith(
        (_) => jsonResponse({
          'counting': {...counting['counting']!, 'started_at': startedAt},
        }, 200),
      );
      final first = await check.counting('c1');
      check.confirmed('c1', first!);
      expect(await check.counting('c1'), isNull);

      startedAt = '2026-10-26T11:00:00Z';
      expect(await check.counting('c1'), isNotNull);
    },
  );

  test('нет связи или старый сервер - null, движение не держим', () async {
    final offline = checkWith(
      (o) => throw DioException.connectionError(
        requestOptions: o,
        reason: 'нет сети',
      ),
    );
    expect(await offline.counting('c1'), isNull);

    final oldServer = checkWith((_) => ResponseBody.fromString('{}', 404));
    expect(await oldServer.counting('c1'), isNull);
  });
}
