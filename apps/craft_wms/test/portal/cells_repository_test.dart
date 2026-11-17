import 'dart:convert';
import 'dart:typed_data';

import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/portal/data/cells_repository.dart';
import 'package:craft_wms/portal/domain/cells/cell_setup.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_dio_adapter.dart';

/// ADHOC-57: репозиторий страницы «Ячейки» - список, правка, выгрузка, печать, загрузка.
void main() {
  late Dio dio;

  setUp(() => dio = Dio(BaseOptions(baseUrl: 'https://api.test')));

  ResponseBody pdf(RequestOptions _) => ResponseBody.fromBytes(
    Uint8List.fromList(utf8.encode('%PDF-')),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/pdf'],
    },
  );

  test(
    'loadSetup - ячейки со стеллажом и признаками, стеллажи; склад SHB',
    () async {
      final adapter = RecordingAdapter({
        'GET ${ApiConst.cellsSetup}': (_) => jsonResponse({
          'warehouse': 'SHB',
          'cells': [
            {
              'id': 'c1',
              'address': 'B-1-3-7',
              'rack_id': 'r1',
              'rack_code': 'B-01',
              'is_floor': true,
              'label_small': false,
              'label_barcode': true,
              'side_card': true,
            },
            {'id': 'c2', 'address': 'X', 'rack_id': null, 'rack_code': null},
          ],
          'racks': [
            {'id': 'r1', 'code': 'B-01'},
          ],
        }, 200),
      });
      dio.httpClientAdapter = adapter;

      final res = await CellsRepository(dio).loadSetup();

      final setup = res.right;
      expect(adapter.requests.single.queryParameters['warehouse'], 'SHB');
      expect(setup.cells.first.rackCode, 'B-01');
      expect(setup.cells.first.isFloor, isTrue);
      expect(setup.cells.first.labelBarcode, isTrue);
      expect(setup.cells.first.tier, 3);
      expect(setup.cells.first.position, 7);
      expect(setup.cells.last.rackId, isNull);
      expect(setup.cells.last.tier, isNull);
      expect(setup.cells.first.sideCard, isTrue);
      expect(setup.cells.last.sideCard, isFalse);
      expect(setup.racks.single.code, 'B-01');
    },
  );

  test('saveSettings - только изменённые галочки в теле PATCH', () async {
    final adapter = RecordingAdapter({
      'PATCH ${ApiConst.cellsSetup}': (_) =>
          jsonResponse({'cells_updated': 2}, 200),
    });
    dio.httpClientAdapter = adapter;

    final res = await CellsRepository(dio).saveSettings(
      ['c1', 'c2'],
      {CellFlag.small: true, CellFlag.sideCard: true},
    );

    expect(res.right, 2);
    expect(adapter.requests.single.data, {
      'cell_ids': ['c1', 'c2'],
      'label_small': true,
      'side_card': true,
    });
  });

  test('saveSettings - ответ без cells_updated не ошибка', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'PATCH ${ApiConst.cellsSetup}': (_) => jsonResponse({}, 200),
    });

    final res = await CellsRepository(
      dio,
    ).saveSettings(['c1'], {CellFlag.sideCard: false});

    expect(res.right, 0);
  });

  test('saveSettings - 409 с текстом сервера', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'PATCH ${ApiConst.cellsSetup}': (_) => jsonResponse({
        'error': 'часть ячеек не найдена на складе - обновите страницу',
      }, 409),
    });

    final res = await CellsRepository(
      dio,
    ).saveSettings(['c1'], {CellFlag.floor: true});

    final f = res.left as ServerFailure;
    expect(f.statusCode, 409);
    expect(f.message, contains('обновите страницу'));
  });

  test('labelsPdf - POST {kind, cell_ids}, ответ байтами', () async {
    final adapter = RecordingAdapter({'POST ${ApiConst.cellLabelsPdf}': pdf});
    dio.httpClientAdapter = adapter;

    final res = await CellsRepository(dio).labelsPdf(LabelKind.cards, ['c1']);

    expect(utf8.decode(res.right), '%PDF-');
    final req = adapter.requests.single;
    expect(req.data, {
      'kind': 'cards',
      'cell_ids': ['c1'],
    });
    expect(req.responseType, ResponseType.bytes);
    expect(req.queryParameters['warehouse'], 'SHB');
  });

  test('labelsPdf - 422: текст ошибки разобран из тела-байтов', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'POST ${ApiConst.cellLabelsPdf}': (_) => jsonResponse({
        'error': 'этикетки не печатаются: адрес B-1-1-1 не влезает',
      }, 422),
    });

    final res = await CellsRepository(dio).labelsPdf(LabelKind.large, const []);

    final f = res.left as ServerFailure;
    expect(f.statusCode, 422);
    expect(f.message, 'этикетки не печатаются: адрес B-1-1-1 не влезает');
  });

  test('exportCells - GET cells/export.xlsx байтами', () async {
    final adapter = RecordingAdapter({'GET ${ApiConst.cellsExport}': pdf});
    dio.httpClientAdapter = adapter;

    final res = await CellsRepository(dio).exportCells();

    expect(res.isRight, isTrue);
    expect(adapter.requests.single.responseType, ResponseType.bytes);
  });

  test('importCells - в отчёте стеллажи', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'POST ${ApiConst.importCells}': (_) => jsonResponse({
        'warehouse': 'SHB',
        'cells_created': 1,
        'cells_updated': 2,
        'racks_created': 3,
        'racks_updated': 4,
        'skipped': [
          {'row': 5, 'message': 'нет адреса'},
        ],
      }, 200),
    });

    final res = await CellsRepository(
      dio,
    ).importCells(bytes: [1], filename: 'cells.xlsx');

    expect(res.right.racksCreated, 3);
    expect(res.right.racksUpdated, 4);
    expect(res.right.skipped.single.row, 5);
  });

  test('нет сети - NetworkFailure', () async {
    dio.httpClientAdapter = RecordingAdapter({
      'GET ${ApiConst.cellsSetup}': (o) => throw DioException(
        requestOptions: o,
        type: DioExceptionType.connectionError,
      ),
    });

    final res = await CellsRepository(dio).loadSetup();

    expect(res.left, isA<NetworkFailure>());
  });
}
