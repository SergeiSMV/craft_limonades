import 'package:craft_wms/core/auth/auth_repository.dart';
import 'package:craft_wms/core/auth/token_storage.dart';
import 'package:craft_wms/core/constants/api_constants.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_dio_adapter.dart';

class _MockTokenStorage extends Mock implements TokenStorage {}

void main() {
  late Dio dio;
  late _MockTokenStorage storage;

  const badge = '1000000023456781';
  const meJson = {
    'user_id': 'user-1',
    'login': '10000000',
    'full_name': 'Тест Тестович',
    'role': 'admin',
  };

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    storage = _MockTokenStorage();
  });

  /// Настраивает адаптер dio на заданные ответы и собирает репозиторий.
  AuthRepository repoWith(
    Map<String, ResponseBody Function(RequestOptions)> responses,
  ) {
    dio.httpClientAdapter = RecordingAdapter(responses);
    return AuthRepository(dio, storage);
  }

  group('login', () {
    test('успех → сохраняет пару токенов и возвращает профиль', () async {
      when(() => storage.save(
            access: any(named: 'access'),
            refresh: any(named: 'refresh'),
          )).thenAnswer((_) async {});
      final repo = repoWith({
        'POST ${ApiConst.loginByBadge}': (_) =>
            jsonResponse({'access': 'acc-1', 'refresh': 'ref-1'}, 200),
        'GET ${ApiConst.me}': (_) => jsonResponse(meJson, 200),
      });

      final result = await repo.login(badge);

      expect(result.isRight, isTrue);
      expect(result.right.login, '10000000');
      expect(result.right.role, 'admin');
      verify(() => storage.save(access: 'acc-1', refresh: 'ref-1')).called(1);
    });

    test('401 → Failure.auth, токены не сохраняются', () async {
      final repo = repoWith({
        'POST ${ApiConst.loginByBadge}': (_) => jsonResponse({}, 401),
      });

      final result = await repo.login(badge);

      expect(result.left, isA<AuthFailure>());
      verifyNever(() => storage.save(
            access: any(named: 'access'),
            refresh: any(named: 'refresh'),
          ));
    });

    test('400 → Failure.auth', () async {
      final repo = repoWith({
        'POST ${ApiConst.loginByBadge}': (_) => jsonResponse({}, 400),
      });

      expect((await repo.login(badge)).left, isA<AuthFailure>());
    });

    test('500 → Failure.server с кодом', () async {
      final repo = repoWith({
        'POST ${ApiConst.loginByBadge}': (_) => jsonResponse({}, 500),
      });

      final result = await repo.login(badge);

      expect(result.left, isA<ServerFailure>());
      expect((result.left as ServerFailure).statusCode, 500);
    });

    test('нет сети → Failure.network', () async {
      final repo = repoWith({
        'POST ${ApiConst.loginByBadge}': (o) => throw DioException(
              requestOptions: o,
              type: DioExceptionType.connectionError,
            ),
      });

      expect((await repo.login(badge)).left, isA<NetworkFailure>());
    });
  });

  group('me', () {
    test('успех → профиль', () async {
      final repo = repoWith({'GET ${ApiConst.me}': (_) => jsonResponse(meJson, 200)});

      final result = await repo.me();

      expect(result.isRight, isTrue);
      expect(result.right.fullName, 'Тест Тестович');
    });

    test('401 → Failure.auth', () async {
      final repo = repoWith({'GET ${ApiConst.me}': (_) => jsonResponse({}, 401)});

      expect((await repo.me()).left, isA<AuthFailure>());
    });
  });

  group('hasSession', () {
    test('есть access-токен → true', () async {
      when(() => storage.readAccess()).thenAnswer((_) async => 'acc');
      final repo = AuthRepository(dio, storage);
      expect(await repo.hasSession(), isTrue);
    });

    test('нет токена → false', () async {
      when(() => storage.readAccess()).thenAnswer((_) async => null);
      final repo = AuthRepository(dio, storage);
      expect(await repo.hasSession(), isFalse);
    });
  });
}
