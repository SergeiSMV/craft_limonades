import 'package:craft_wms/core/auth/token_storage.dart';
import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/network/auth_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_dio_adapter.dart';

class _MockTokenStorage extends Mock implements TokenStorage {}

void main() {
  late _MockTokenStorage storage;

  setUp(() => storage = _MockTokenStorage());

  /// Собирает пару Dio: основной (с AuthInterceptor) и «голый» tokenDio.
  ({Dio dio, RecordingAdapter main, RecordingAdapter token}) build({
    required Map<String, ResponseBody Function(RequestOptions)> mainResponses,
    required Map<String, ResponseBody Function(RequestOptions)> tokenResponses,
  }) {
    final tokenDio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    final tokenAdapter = RecordingAdapter(tokenResponses);
    tokenDio.httpClientAdapter = tokenAdapter;

    final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    final mainAdapter = RecordingAdapter(mainResponses);
    dio.httpClientAdapter = mainAdapter;
    dio.interceptors.add(AuthInterceptor(storage, tokenDio));

    return (dio: dio, main: mainAdapter, token: tokenAdapter);
  }

  test('onRequest подставляет Bearer, когда access есть', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => 'tok');
    final h = build(
      mainResponses: {'GET /ping': (_) => jsonResponse({'ok': true}, 200)},
      tokenResponses: {},
    );

    await h.dio.get<dynamic>('/ping');

    expect(h.main.requests.single.headers['Authorization'], 'Bearer tok');
  });

  test('onRequest не ставит заголовок, когда access нет', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => null);
    final h = build(
      mainResponses: {'GET /ping': (_) => jsonResponse({'ok': true}, 200)},
      tokenResponses: {},
    );

    await h.dio.get<dynamic>('/ping');

    expect(h.main.requests.single.headers.containsKey('Authorization'), isFalse);
  });

  test('401 → refresh → повтор с новым токеном → 200', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => 'old');
    when(() => storage.readRefresh()).thenAnswer((_) async => 'refresh-token');
    when(() => storage.saveAccess(any())).thenAnswer((_) async {});

    final h = build(
      mainResponses: {'GET /protected': (_) => jsonResponse({}, 401)},
      tokenResponses: {
        'POST ${ApiConst.refreshToken}': (_) => jsonResponse({'access': 'new-access'}, 200),
        'GET /protected': (_) => jsonResponse({'ok': true}, 200),
      },
    );

    final resp = await h.dio.get<dynamic>('/protected');

    expect(resp.statusCode, 200);
    expect((resp.data as Map)['ok'], isTrue);
    verify(() => storage.saveAccess('new-access')).called(1);
    // Повторный запрос ушёл с новым токеном.
    final replay = h.token.requests.firstWhere((r) => r.path == '/protected');
    expect(replay.headers['Authorization'], 'Bearer new-access');
  });

  test('ошибка не 401 пробрасывается без попытки refresh', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => 'old');
    final h = build(
      mainResponses: {'GET /protected': (_) => jsonResponse({}, 500)},
      tokenResponses: {},
    );

    await expectLater(
      h.dio.get<dynamic>('/protected'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          500,
        ),
      ),
    );
    verifyNever(() => storage.readRefresh());
    verifyNever(() => storage.saveAccess(any()));
  });

  test('401 без refresh-токена пробрасывает ошибку, хранилище не чистим', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => 'old');
    when(() => storage.readRefresh()).thenAnswer((_) async => null);
    final h = build(
      mainResponses: {'GET /protected': (_) => jsonResponse({}, 401)},
      tokenResponses: {},
    );

    await expectLater(
      h.dio.get<dynamic>('/protected'),
      throwsA(isA<DioException>()),
    );
    verifyNever(() => storage.saveAccess(any()));
    verifyNever(() => storage.clear());
  });

  test('протухший refresh (401 на /auth/refresh) → чистим хранилище', () async {
    when(() => storage.readAccess()).thenAnswer((_) async => 'old');
    when(() => storage.readRefresh()).thenAnswer((_) async => 'refresh-token');
    when(() => storage.clear()).thenAnswer((_) async {});

    final h = build(
      mainResponses: {'GET /protected': (_) => jsonResponse({}, 401)},
      tokenResponses: {'POST ${ApiConst.refreshToken}': (_) => jsonResponse({}, 401)},
    );

    await expectLater(
      h.dio.get<dynamic>('/protected'),
      throwsA(isA<DioException>()),
    );
    verify(() => storage.clear()).called(1);
    verifyNever(() => storage.saveAccess(any()));
  });
}
