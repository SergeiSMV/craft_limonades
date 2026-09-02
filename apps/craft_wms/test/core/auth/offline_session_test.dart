import 'package:craft_wms/core/auth/auth_cubit.dart';
import 'package:craft_wms/core/auth/auth_repository.dart';
import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements AuthRepository {}

/// Вход без сети (P2-02): терминал, перезагруженный вне зоны Wi-Fi, должен пускать к работе,
/// иначе весь офлайн-кэш недостижим.
void main() {
  const profile = Profile(
    userId: 'u1',
    login: '10000000',
    fullName: 'Кладовщик',
    role: 'employee',
  );

  late _MockRepo repo;
  late AuthCubit cubit;

  setUp(() {
    repo = _MockRepo();
    when(() => repo.hasSession()).thenAnswer((_) async => true);
    cubit = AuthCubit(repo);
  });

  tearDown(() => cubit.close());

  test('нет сети + живая локальная сессия → пускаем работать', () async {
    when(() => repo.me()).thenAnswer((_) async => const Left(Failure.network()));
    when(() => repo.offlineSession()).thenAnswer((_) async => profile);

    await cubit.restore();

    expect(cubit.state, isA<AuthAuthenticated>());
    expect((cubit.state as AuthAuthenticated).profile.fullName, 'Кладовщик');
  });

  test('нет сети и нет локальной сессии → экран входа', () async {
    when(() => repo.me()).thenAnswer((_) async => const Left(Failure.network()));
    when(() => repo.offlineSession()).thenAnswer((_) async => null);

    await cubit.restore();

    expect(cubit.state, isA<AuthUnauthenticated>());
  });

  test('отказ сервера НЕ подменяется локальной сессией', () async {
    // Протухший refresh — это ответ сервера, а не отсутствие связи: пускать нельзя,
    // иначе отозванный доступ продолжал бы работать при живой сети.
    when(() => repo.me()).thenAnswer((_) async => const Left(Failure.auth()));
    when(() => repo.offlineSession()).thenAnswer((_) async => profile);

    await cubit.restore();

    expect(cubit.state, isA<AuthUnauthenticated>());
    verifyNever(() => repo.offlineSession());
  });

  test('сеть есть → идём на сервер, локальная сессия не нужна', () async {
    when(() => repo.me()).thenAnswer((_) async => const Right(profile));

    await cubit.restore();

    expect(cubit.state, isA<AuthAuthenticated>());
    verifyNever(() => repo.offlineSession());
  });

  test('без сохранённых токенов сеть вообще не трогаем', () async {
    when(() => repo.hasSession()).thenAnswer((_) async => false);

    await cubit.restore();

    expect(cubit.state, isA<AuthUnauthenticated>());
    verifyNever(() => repo.me());
  });
}
