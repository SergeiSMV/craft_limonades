import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/stock/data/catalog_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_dio_adapter.dart';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  });

  /// Настраивает адаптер dio на заданные ответы и собирает репозиторий.
  CatalogRepository repoWith(
    Map<String, ResponseBody Function(RequestOptions)> responses,
  ) {
    dio.httpClientAdapter = RecordingAdapter(responses);
    return CatalogRepository(dio);
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
        'GET ${ApiConst.goods}': (_) =>
            jsonResponse({'items': [], 'total': 0, 'limit': 50, 'offset': 0}, 200),
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
        'GET ${ApiConst.goods}': (options) =>
            throw DioException(requestOptions: options, type: DioExceptionType.connectionError),
      });
      final repo = CatalogRepository(dio);

      final result = await repo.listGoods();

      expect(result.isLeft, isTrue);
      expect(result.left, isA<NetworkFailure>());
    });
  });

  group('listStock', () {
    test('успех → строки остатка, qty сохраняется строкой (точный decimal)', () async {
      final repo = repoWith({
        'GET ${ApiConst.stock}': (_) => jsonResponse({
              'items': [
                {
                  'cell_id': 'c1',
                  'cell_address': 'M1-1-1-1',
                  'good_id': 'g1',
                  'batch_id': 'b1',
                  'production_date': '2026-01-15',
                  'qty': '10.5',
                },
              ],
              'total': 1,
              'limit': 200,
              'offset': 0,
            }, 200),
      });

      final result = await repo.listStock(goodId: 'g1');

      expect(result.isRight, isTrue);
      final item = result.right.items.single;
      expect(item.cellAddress, 'M1-1-1-1');
      expect(item.productionDate, '2026-01-15');
      expect(item.qty, '10.5');
    });
  });

  group('listGoodBarcodes / unbindBarcode (P-FS-12)', () {
    test('listGoodBarcodes: массив ШК парсится (symbology может быть null)', () async {
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
    });

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

    test('unbindBarcode: DELETE 204 → Right', () async {
      final adapter = RecordingAdapter({
        'DELETE ${ApiConst.barcodeByCode("460")}': (_) => ResponseBody.fromString('', 204),
      });
      dio.httpClientAdapter = adapter;
      final repo = CatalogRepository(dio);

      final result = await repo.unbindBarcode('460');

      expect(result.isRight, isTrue);
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.path, ApiConst.barcodeByCode('460'));
    });

    test('unbindBarcode: 401 → Failure.auth', () async {
      final repo = repoWith({
        'DELETE ${ApiConst.barcodeByCode("460")}': (_) => jsonResponse({}, 401),
      });

      final result = await repo.unbindBarcode('460');
      expect(result.isLeft, isTrue);
      expect(result.left, isA<AuthFailure>());
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
}
