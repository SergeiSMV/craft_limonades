import 'package:craft_wms/core/app_update/app_update_cubit.dart';
import 'package:craft_wms/core/app_update/app_update_service.dart';
import 'package:craft_wms/core/auth/auth_cubit.dart';
import 'package:craft_wms/core/auth/auth_repository.dart';
import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/core/outbox/outbox_repository.dart';
import 'package:craft_wms/core/scanner/scan_event.dart';
import 'package:craft_wms/core/theme/app_theme.dart';
import 'package:craft_wms/features/auth/presentation/pages/login_page.dart';
import 'package:craft_wms/features/auth/presentation/widgets/badge_scan_view.dart';
import 'package:craft_wms/features/auth/presentation/widgets/password_login_view.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../support/fake_scanner_service.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockAppUpdateService extends Mock implements AppUpdateService {}

class _MockOutbox extends Mock implements OutboxRepository {}

/// Устройство со сканером - как боевой DT50S.
const _tsd = ScannerProbe(
  available: true,
  packages: ['com.ubx.uscanner'],
  manufacturer: 'UBX',
  brand: 'UROVO',
  model: 'DT50',
  device: 'DT50S',
  actions: ['android.intent.ACTION_DECODE_DATA'],
);

/// Экран входа: форма выбирается по возможностям устройства, а бейдж принимается
/// и из поля ввода, и из потока аппаратного сканера.
void main() {
  late _MockAuthRepository repo;
  late AuthCubit cubit;

  setUp(() {
    LocaleSettings.useDeviceLocale();
    repo = _MockAuthRepository();
    when(
      () => repo.login(any()),
    ).thenAnswer((_) async => const Left(Failure.auth('Неверный бейдж')));
    when(() => repo.loginWithPassword(any(), any())).thenAnswer(
      (_) async => const Left(Failure.auth('Неверный логин или пароль')),
    );
    cubit = AuthCubit(repo);
    // Экран входа проверяет обновление приложения (ADHOC-69); в тестах магазина нет.
    final updates = _MockAppUpdateService();
    when(() => updates.supported).thenReturn(false);
    if (getIt.isRegistered<AppUpdateCubit>()) {
      getIt.unregister<AppUpdateCubit>();
    }
    getIt.registerFactory<AppUpdateCubit>(
      () => AppUpdateCubit(updates, _MockOutbox(), Talker()),
    );
  });

  tearDown(() => cubit.close());

  Widget wrap() => MaterialApp(
    theme: buildAppTheme(),
    home: BlocProvider<AuthCubit>.value(value: cubit, child: const LoginPage()),
  );

  testWidgets('на ТСД со сканером показан вход по бейджу', (tester) async {
    registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.byType(BadgeScanView), findsOneWidget);
    expect(find.byType(PasswordLoginView), findsNothing);
  });

  testWidgets('на устройстве без сканера показан вход по логину и паролю', (
    tester,
  ) async {
    registerFakeScanner(); // сканера нет - обычный смартфон
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.byType(PasswordLoginView), findsOneWidget);
    expect(find.byType(BadgeScanView), findsNothing);
  });

  testWidgets('форму входа можно переключить вручную', (tester) async {
    registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.text(t.loginScreen.usePassword));
    await tester.pump();
    expect(find.byType(PasswordLoginView), findsOneWidget);

    await tester.tap(find.text(t.loginScreen.useBadge));
    await tester.pump();
    expect(find.byType(BadgeScanView), findsOneWidget);
  });

  testWidgets('бейдж из потока сканера уходит на вход без ввода в поле', (
    tester,
  ) async {
    final scanner = registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();

    scanner.emit('1000000012345678');
    await tester.pump();

    verify(() => repo.login('1000000012345678')).called(1);
    await scanner.dispose();
  });

  testWidgets('повторная доставка того же бейджа входа не удваивает', (
    tester,
  ) async {
    final scanner = registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();

    scanner.emit('1000000012345678');
    scanner.emit('1000000012345678'); // тот же код вторым источником
    await tester.pump();

    verify(() => repo.login('1000000012345678')).called(1);
    await scanner.dispose();
  });

  testWidgets('поле и поток отдают тот же бейдж - вход уходит один раз', (
    tester,
  ) async {
    // Регресс: отсечение дубля сидело только на ветке потока, и пара «поле + интент»
    // проходила мимо него. Проверка идёт именно через поле, а не через второй скан.
    final scanner = registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), '1000000012345678');
    await tester.pump();
    scanner.emit('1000000012345678');
    await tester.pump();

    verify(() => repo.login('1000000012345678')).called(1);
    await scanner.dispose();
  });

  testWidgets('в режиме логина/пароля скан бейджа игнорируется', (
    tester,
  ) async {
    final scanner = registerFakeScanner(); // смартфон: сразу форма логина
    await tester.pumpWidget(wrap());
    await tester.pump();

    scanner.emit('1000000012345678');
    await tester.pump();

    verifyNever(() => repo.login(any()));
    await scanner.dispose();
  });

  testWidgets('обе формы входа переживают короткий вьюпорт', (tester) async {
    // Регресс: при автоповороте на DT50S высота падала до 360 dp, а колонка экрана бейджа
    // просила ~485 - RenderFlex рвался «зеброй» на 128 px. Приложение с тех пор заблокировано
    // в портрете, но короткий вьюпорт остаётся штатным: его даёт экранная клавиатура.
    tester.view.physicalSize = const Size(1344, 720);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final scanner = registerFakeScanner(probe: _tsd);
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'форма скана бейджа');

    // В ландшафте ссылка уходит под сгиб - до неё именно прокручиваются. Это и проверяем:
    // содержимое доступно целиком, а не обрезано.
    await tester.ensureVisible(find.text(t.loginScreen.usePassword));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.loginScreen.usePassword));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'форма логина и пароля');

    await scanner.dispose();
  });

  testWidgets('пустые учётные данные до сети не доходят', (tester) async {
    registerFakeScanner();
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.text(t.loginScreen.signIn));
    await tester.pump();

    verifyNever(() => repo.loginWithPassword(any(), any()));
    expect(find.text(t.loginScreen.errorEmptyCredentials), findsOneWidget);
  });

  testWidgets('заполненные учётные данные уходят на вход по паролю', (
    tester,
  ) async {
    registerFakeScanner();
    when(() => repo.loginWithPassword('admin', 'secret')).thenAnswer(
      (_) async => const Right(
        Profile(userId: 'u1', login: 'admin', fullName: 'Админ', role: 'admin'),
      ),
    );
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'admin');
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.tap(find.text(t.loginScreen.signIn));
    await tester.pump();

    verify(() => repo.loginWithPassword('admin', 'secret')).called(1);
  });
}
