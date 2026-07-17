import 'package:bloc_test/bloc_test.dart';
import 'package:craft_wms/core/auth/auth_cubit.dart';
import 'package:craft_wms/core/auth/auth_repository.dart';
import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:either_dart/either.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late _MockAuthRepository repo;

  const profile = Profile(
    userId: 'user-1',
    login: '10000000',
    fullName: 'Тест Тестович',
    role: 'admin',
  );
  const badge = '1000000023456781';

  setUp(() => repo = _MockAuthRepository());

  group('login', () {
    blocTest<AuthCubit, AuthState>(
      'успех → [authenticating, authenticated(profile)]',
      build: () {
        when(() => repo.login(any()))
            .thenAnswer((_) async => const Right(profile));
        return AuthCubit(repo);
      },
      act: (cubit) => cubit.login(badge),
      expect: () => const [
        AuthState.authenticating(),
        AuthState.authenticated(profile),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'неудача → [authenticating, unauthenticated(failure)]',
      build: () {
        when(() => repo.login(any()))
            .thenAnswer((_) async => const Left(Failure.auth('Неверный бейдж')));
        return AuthCubit(repo);
      },
      act: (cubit) => cubit.login(badge),
      expect: () => const [
        AuthState.authenticating(),
        AuthState.unauthenticated(Failure.auth('Неверный бейдж')),
      ],
    );
  });

  blocTest<AuthCubit, AuthState>(
    'logout → [unauthenticated]',
    build: () {
      when(() => repo.logout()).thenAnswer((_) async {});
      return AuthCubit(repo);
    },
    act: (cubit) => cubit.logout(),
    expect: () => const [AuthState.unauthenticated()],
    verify: (_) => verify(() => repo.logout()).called(1),
  );

  group('restore', () {
    blocTest<AuthCubit, AuthState>(
      'нет токенов → [unauthenticated], в сеть не ходим',
      build: () {
        when(() => repo.hasSession()).thenAnswer((_) async => false);
        return AuthCubit(repo);
      },
      act: (cubit) => cubit.restore(),
      expect: () => const [AuthState.unauthenticated()],
      verify: (_) => verifyNever(() => repo.me()),
    );

    blocTest<AuthCubit, AuthState>(
      'есть токены + me успех → [authenticated(profile)] (без authenticating)',
      build: () {
        when(() => repo.hasSession()).thenAnswer((_) async => true);
        when(() => repo.me()).thenAnswer((_) async => const Right(profile));
        return AuthCubit(repo);
      },
      act: (cubit) => cubit.restore(),
      expect: () => const [AuthState.authenticated(profile)],
    );

    blocTest<AuthCubit, AuthState>(
      'есть токены + me неудача → [unauthenticated(failure)]',
      build: () {
        when(() => repo.hasSession()).thenAnswer((_) async => true);
        when(() => repo.me())
            .thenAnswer((_) async => const Left(Failure.network()));
        return AuthCubit(repo);
      },
      act: (cubit) => cubit.restore(),
      expect: () => const [AuthState.unauthenticated(Failure.network())],
    );
  });
}
