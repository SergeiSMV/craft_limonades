import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/database/app_database.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/warehouse/internal_warehouses.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

/// Справочник внутренних складов на ТСД (P6-07-2).
void main() {
  late AppDatabase db;
  late _MockDio dio;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dio = _MockDio();
  });

  tearDown(() => db.close());

  Response<List<dynamic>> ok(List<dynamic> data) => Response(
    requestOptions: RequestOptions(path: ApiConst.internalWarehouses),
    statusCode: 200,
    data: data,
  );

  test(
    'загрузка укладывает склады; «Основной» — первым и он же по умолчанию',
    () async {
      when(
        () => dio.get<List<dynamic>>(ApiConst.internalWarehouses),
      ).thenAnswer(
        (_) async => ok([
          {'id': 'm', 'code': 'MAIN', 'name': 'Основной', 'is_default': true},
          {'id': 'd', 'code': 'DEFECT', 'name': 'Брак', 'is_default': false},
        ]),
      );
      final w = InternalWarehouses(dio, db);
      expect((await w.refresh()).isRight, isTrue);

      // Новый экземпляр — читает из базы, а не из памяти.
      final fresh = InternalWarehouses(dio, db);
      expect((await fresh.all()).map((x) => x.name), ['Основной', 'Брак']);
      expect(await fresh.defaultId(), 'm');
    },
  );

  test(
    'сервер без ручки (404) — не сбой: справочник остаётся прежним',
    () async {
      when(() => dio.get<List<dynamic>>(ApiConst.internalWarehouses)).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: ApiConst.internalWarehouses),
          response: Response(
            requestOptions: RequestOptions(path: ApiConst.internalWarehouses),
            statusCode: 404,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      final w = InternalWarehouses(dio, db);
      expect((await w.refresh()).isRight, isTrue);
      expect(await w.all(), isEmpty);
      expect(await w.defaultId(), isNull);
    },
  );

  test(
    'нет связи — сбой, который синхронизация лишь запишет в журнал',
    () async {
      when(() => dio.get<List<dynamic>>(ApiConst.internalWarehouses)).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: ApiConst.internalWarehouses),
          type: DioExceptionType.connectionError,
        ),
      );
      final res = await InternalWarehouses(dio, db).refresh();
      expect(res.left, isA<NetworkFailure>());
    },
  );

  test('соглашение терминала: склад по умолчанию и пусто — null', () {
    expect(InternalWarehouses.normalize('m', 'm'), isNull);
    expect(InternalWarehouses.normalize('', 'm'), isNull);
    expect(InternalWarehouses.normalize(null, 'm'), isNull);
    expect(InternalWarehouses.normalize('d', 'm'), 'd');
  });
}
