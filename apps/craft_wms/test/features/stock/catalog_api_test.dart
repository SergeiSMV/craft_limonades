import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/data/catalog_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  /// Настраивает адаптер dio на заданные ответы и собирает репозиторий.
  CatalogApi repoWith(
    Map<String, ResponseBody Function(RequestOptions)> responses,
  ) {
    dio.httpClientAdapter = RecordingAdapter(responses);
    return CatalogApi(dio);
  }

  group('listGoods', () {
    test('успех → парсит страницу товаров с присоединёнными именами', () async {
      final repo = repoWith({
        'GET ${ApiConst.goods}': (_) => jsonResponse({
          'items': [
            {
              'id': 'g1',
              'code': '16121',
              'name': 'Кальмар кольца',
              'full_name': 'Кальмар кольца Премиум',
              'uom': 'шт',
              'group_id': 'gr1',
              'group_name': 'КАЛЬМАРОВАЯ ГРУППА',
              'supplier_id': 'sp1',
              'supplier_name': 'ООО ТОРГМАРКЕТ',
              'is_active': true,
            },
          ],
          'total': 15,
          'limit': 50,
          'offset': 0,
        }, 200),
      });

      final result = await repo.listGoods(query: 'кальмар');

      expect(result.isRight, isTrue);
      final page = result.right;
      expect(page.total, 15);
      expect(page.items, hasLength(1));
      expect(page.items.first.code, '16121');
      expect(page.items.first.groupName, 'КАЛЬМАРОВАЯ ГРУППА');
      expect(page.items.first.supplierName, 'ООО ТОРГМАРКЕТ');
    });

    test('пустой список → items = [] (не падает)', () async {
      final repo = repoWith({
        'GET ${ApiConst.goods}': (_) => jsonResponse({
          'items': [],
          'total': 0,
          'limit': 50,
          'offset': 0,
        }, 200),
      });

      final result = await repo.listGoods();

      expect(result.isRight, isTrue);
      expect(result.right.items, isEmpty);
      expect(result.right.total, 0);
    });

    test('401 → Failure.auth', () async {
      final repo = repoWith({
        'GET ${ApiConst.goods}': (_) => jsonResponse({}, 401),
      });

      final result = await repo.listGoods();

      expect(result.isLeft, isTrue);
      expect(result.left, isA<AuthFailure>());
    });

    test('нет сети → Failure.network', () async {
      dio.httpClientAdapter = RecordingAdapter({
        'GET ${ApiConst.goods}': (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      });
      final repo = CatalogApi(dio);

      final result = await repo.listGoods();

      expect(result.isLeft, isTrue);
      expect(result.left, isA<NetworkFailure>());
    });
  });

  group('listGoodBarcodes / unbindBarcode (P-FS-12)', () {
    test(
      'listGoodBarcodes: массив ШК парсится (symbology может быть null)',
      () async {
        final repo = repoWith({
          'GET ${ApiConst.goodBarcodes("g1")}': (_) => ResponseBody.fromString(
            '[{"barcode":"460","symbology":"ean13"},{"barcode":"BOX","symbology":null}]',
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ),
        });

        final result = await repo.listGoodBarcodes('g1');

        expect(result.isRight, isTrue);
        expect(result.right, hasLength(2));
        expect(result.right.first.barcode, '460');
        expect(result.right.first.symbology, 'ean13');
        expect(result.right.last.symbology, isNull);
      },
    );

    test('listGoodBarcodes: пустой список → []', () async {
      final repo = repoWith({
        'GET ${ApiConst.goodBarcodes("g1")}': (_) => ResponseBody.fromString(
          '[]',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });

      final result = await repo.listGoodBarcodes('g1');
      expect(result.isRight, isTrue);
      expect(result.right, isEmpty);
    });
  });

  group('listAllCells (пагинация до конца, P-FS-13)', () {
    List<Map<String, dynamic>> cellsRange(int from, int to) => [
      for (var i = from; i < to; i++)
        {'id': 'c$i', 'warehouse_id': 'w', 'address': 'A-$i'},
    ];

    test('склеивает все страницы по 200 до total', () async {
      final adapter = RecordingAdapter({
        'GET ${ApiConst.cells}': (o) {
          final offset = int.parse('${o.queryParameters['offset']}');
          final items = offset == 0 ? cellsRange(0, 200) : cellsRange(200, 250);
          return jsonResponse({
            'items': items,
            'total': 250,
            'limit': 200,
            'offset': offset,
          }, 200);
        },
      });
      dio.httpClientAdapter = adapter;
      final repo = CatalogApi(dio);

      final res = await repo.listAllCells();

      expect(res.isRight, isTrue);
      expect(res.right.length, 250);
      expect(res.right.first.address, 'A-0');
      expect(res.right.last.address, 'A-249');
      // Ровно два запроса: offset 0 и 200.
      expect(adapter.requests.length, 2);
      expect(adapter.requests[0].queryParameters['offset'], 0);
      expect(adapter.requests[1].queryParameters['offset'], 200);
    });

    test('ошибка страницы → Left, дальнейшие страницы не тянем', () async {
      final adapter = RecordingAdapter({
        'GET ${ApiConst.cells}': (o) {
          final offset = int.parse('${o.queryParameters['offset']}');
          if (offset == 0) {
            return jsonResponse({
              'items': cellsRange(0, 200),
              'total': 250,
              'limit': 200,
              'offset': 0,
            }, 200);
          }
          return jsonResponse({'error': 'boom'}, 500);
        },
      });
      dio.httpClientAdapter = adapter;
      final repo = CatalogApi(dio);

      final res = await repo.listAllCells();

      expect(res.isLeft, isTrue);
      expect(adapter.requests.length, 2); // первая ок, вторая упала — стоп
    });
  });

  group('listGroups / listSuppliers', () {
    test('группы парсятся из массива', () async {
      final repo = repoWith({
        'GET ${ApiConst.nomenclatureGroups}': (_) => ResponseBody.fromString(
          '[{"id":"gr1","code":"5046","name":"КАЛЬМАРОВАЯ ГРУППА","parent_id":"gr0"}]',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      });

      final result = await repo.listGroups();

      expect(result.isRight, isTrue);
      expect(result.right.single.code, '5046');
      expect(result.right.single.parentId, 'gr0');
    });
  });

  group('resolveGoodByBarcode (P-FS-16)', () {
    test('привязанный ШК → товар', () async {
      final repo = repoWith({
        'GET ${ApiConst.barcodeByCode('4607044662964')}': (_) => jsonResponse({
          'id': 'g1',
          'code': '15567',
          'name': 'Арахис жареный',
          'uom': 'шт',
        }, 200),
      });

      final result = await repo.resolveGoodByBarcode('4607044662964');

      expect(result.isRight, isTrue);
      expect(result.right!.id, 'g1');
    });

    test('непривязанный ШК (404) → null, а не ошибка', () async {
      final repo = repoWith({
        'GET ${ApiConst.barcodeByCode('0000000000000')}': (_) =>
            jsonResponse(<String, dynamic>{}, 404),
      });

      final result = await repo.resolveGoodByBarcode('0000000000000');

      expect(result.isRight, isTrue);
      expect(result.right, isNull);
    });
  });
}
