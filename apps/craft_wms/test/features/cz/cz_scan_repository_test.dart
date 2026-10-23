import 'dart:convert';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/features/cz/data/cz_scan_dto.dart';
import 'package:craft_wms/features/cz/data/cz_scan_repository_impl.dart';
import 'package:craft_wms/features/cz/domain/cz_scan.dart';
import 'package:craft_wms/features/cz/presentation/bloc/cz_scan_cubit.dart';
import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

class _MockRepo extends Mock implements CzScanRepository {}

/// Эталоны ответа скана — общие с сервером (`cz_scan_http_test.go`): сервер обязан отдавать
/// ровно их, терминал — разбирать.
Map<String, dynamic> _golden(String name) =>
    jsonDecode(
          File('../backend/internal/handler/testdata/$name').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// Скан «Честного знака» на терминале (CZ-04): разбор ответа, репозиторий, cubit.
void main() {
  setUpAll(() => registerFallbackValue(Options()));

  group('разбор эталонов сервера', () {
    test('марка: данные ЧЗ, товар справочника, место в WMS', () {
      final r = czScanFromJson(_golden('cz_scan_mark.json'));
      expect(r.kind, CzCodeKind.unit);
      expect(r.code, '0104612728200172215AmxPmd');
      expect(r.gtin, '04612728200172');
      expect(r.productName, contains('Голубые Гавайи'));
      expect(r.producedDate, DateTime(2026, 10, 12));
      expect(r.expirationDate, DateTime(2027, 4, 10));
      // Наименование ЧЗ и товар справочника — разные поля.
      expect(r.good?.name, 'Пиво «Голубые Гавайи», кега 30 л');
      expect(r.bindBarcode, isNull);
      expect(r.mark?.inStock, isTrue);
      expect(r.mark?.loadUnitId, '22222222-0000-4000-8000-000000000001');
      expect(r.mark?.loadUnitCellId, '33333333-0000-4000-8000-000000000001');
      expect(r.mark?.receivedAt, DateTime.utc(2026, 10, 23, 9));
      expect(r.mark?.cellAddress, 'M1-1-10-1');
      expect(r.composition, isEmpty);
    });

    test('короб: ГЕ и состав по товару и партии', () {
      final r = czScanFromJson(_golden('cz_scan_box.json'));
      expect(r.kind, CzCodeKind.box);
      expect(r.good, isNull);
      expect(r.mark, isNull);
      expect(r.loadUnitId, '22222222-0000-4000-8000-000000000001');
      expect(r.units, 2);
      expect(r.unreadable, ['0104612728200172215broken']);
      final line = r.composition.single;
      expect(line.count, 2);
      expect(line.producedDate, DateTime(2026, 10, 12));
      expect(line.good?.id, '11111111-0000-4000-8000-000000000001');
      expect(line.cis, hasLength(2));
    });

    test('GTIN незнаком: товара нет, есть ШК для привязки', () {
      final j = _golden('cz_scan_mark.json')
        ..['good'] = null
        ..['bind_barcode'] = '4612728200172';
      final r = czScanFromJson(j);
      expect(r.good, isNull);
      expect(r.bindBarcode, '4612728200172');
    });
  });

  group('CzScanRepositoryImpl', () {
    late _MockDio dio;
    late CzScanRepositoryImpl repo;
    const raw = ']d2\u001d0104612728200172215AmxPmd\u001d93dGVz';

    setUp(() {
      dio = _MockDio();
      repo = CzScanRepositoryImpl(dio);
    });

    void answer(Future<Response<Map<String, dynamic>>> Function() f) => when(
      () => dio.post<Map<String, dynamic>>(
        ApiConst.czScan,
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((_) => f());

    test('код уходит в теле как есть, ответ разбирается', () async {
      answer(
        () async => Response(
          requestOptions: RequestOptions(path: ApiConst.czScan),
          statusCode: 200,
          data: _golden('cz_scan_mark.json'),
        ),
      );
      final res = await repo.scan(raw);
      expect(res.isRight, isTrue);
      expect(res.right.good?.id, '11111111-0000-4000-8000-000000000001');
      final sent = verify(
        () => dio.post<Map<String, dynamic>>(
          ApiConst.czScan,
          data: captureAny(named: 'data'),
          options: any(named: 'options'),
        ),
      ).captured.single;
      expect(sent, {'code': raw});
    });

    test('обрыв связи — network', () async {
      answer(
        () => Future.error(
          DioException(
            requestOptions: RequestOptions(path: ApiConst.czScan),
            type: DioExceptionType.connectionError,
          ),
        ),
      );
      expect((await repo.scan(raw)).left, isA<NetworkFailure>());
    });

    test('отказ сервера — с его текстом', () async {
      answer(
        () => Future.error(
          DioException(
            requestOptions: RequestOptions(path: ApiConst.czScan),
            response: Response(
              requestOptions: RequestOptions(path: ApiConst.czScan),
              statusCode: 422,
              data: {'error': 'нет договора с ЧЗ по товарной группе: water'},
            ),
          ),
        ),
      );
      final f = (await repo.scan(raw)).left;
      expect(f, isA<ServerFailure>());
      expect((f as ServerFailure).statusCode, 422);
      expect(f.message, contains('договора'));
    });
  });

  group('CzScanCubit', () {
    late _MockRepo repo;
    final result = czScanFromJson(_golden('cz_scan_mark.json'));

    setUp(() => repo = _MockRepo());

    blocTest<CzScanCubit, CzScanState>(
      'скан → чтение → ответ',
      setUp: () =>
          when(() => repo.scan('M')).thenAnswer((_) async => Right(result)),
      build: () => CzScanCubit(repo),
      act: (c) => c.scan('M'),
      expect: () => [
        const CzScanState(status: CzScanStatus.loading, code: 'M'),
        CzScanState(status: CzScanStatus.loaded, code: 'M', result: result),
      ],
    );

    blocTest<CzScanCubit, CzScanState>(
      'нет связи → отказ',
      setUp: () => when(
        () => repo.scan('M'),
      ).thenAnswer((_) async => const Left(Failure.network())),
      build: () => CzScanCubit(repo),
      act: (c) => c.scan('M'),
      expect: () => [
        const CzScanState(status: CzScanStatus.loading, code: 'M'),
        const CzScanState(
          status: CzScanStatus.error,
          code: 'M',
          failure: Failure.network(),
        ),
      ],
    );

    blocTest<CzScanCubit, CzScanState>(
      'пока код читается, новый скан отбрасывается',
      setUp: () => when(() => repo.scan(any())).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return Right(result);
      }),
      build: () => CzScanCubit(repo),
      act: (c) {
        c.scan('M1');
        c.scan('M2');
      },
      wait: const Duration(milliseconds: 50),
      verify: (_) {
        verify(() => repo.scan('M1')).called(1);
        verifyNever(() => repo.scan('M2'));
      },
    );
  });
}
