import 'package:craft_wms/core/di/injection.dart';
import 'package:craft_wms/core/error/failure.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:craft_wms/portal/data/users_repository.dart';
import 'package:craft_wms/portal/presentation/widgets/common/neumorphic_icon_button.dart';
import 'package:craft_wms/portal/presentation/widgets/settings/users_section.dart';
import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements UsersRepository {}

const _admin = PortalPosition(
  id: 'pa',
  name: 'Администратор',
  rights: ['tsd', 'portal', 'users'],
  isSystem: true,
  users: 1,
);
const _worker = PortalPosition(
  id: 'pw',
  name: 'Кладовщик',
  rights: ['tsd'],
  isSystem: false,
  users: 1,
);

const _me = PortalUser(
  id: 'me',
  fullName: 'Я Админ',
  positionId: 'pa',
  positionName: 'Администратор',
  login: '',
  username: 'admin',
  isActive: true,
);
const _ivan = PortalUser(
  id: 'ivan',
  fullName: 'Иван Кладовщик',
  positionId: 'pw',
  positionName: 'Кладовщик',
  login: '55000001',
  username: '',
  isActive: true,
);

/// ADHOC-50: раздел «Пользователи» в настройках портала.
void main() {
  late _MockRepo repo;
  final changes = ValueNotifier<int>(0);

  setUpAll(() {
    registerFallbackValue((
      fullName: '',
      positionId: '',
      badge: null,
      username: null,
      password: null,
    ));
  });

  setUp(() async {
    LocaleSettings.useDeviceLocale();
    await getIt.reset();
    repo = _MockRepo();
    getIt.registerSingleton<UsersRepository>(repo);
    when(repo.users).thenAnswer((_) async => const Right([_me, _ivan]));
    when(
      repo.positions,
    ).thenAnswer((_) async => const Right([_admin, _worker]));
  });

  tearDown(getIt.reset);

  /// [textScale] < 1 — для узкого экрана: тестовый шрифт заметно шире Inter, и надпись
  /// «Добавить пользователя», которая на настоящем шрифте помещается, в нём не влезает.
  Future<void> pump(
    WidgetTester tester, {
    double width = 1000,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 900),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: UsersSection(changes: changes, selfId: 'me'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('каждый факт своей строкой; себя не заблокировать', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.text(t.portal.users.position(name: 'Кладовщик')),
      findsOneWidget,
    );
    expect(find.text(t.portal.users.badge(login: '55000001')), findsOneWidget);
    expect(find.text(t.portal.users.username(login: 'admin')), findsOneWidget);

    final tooltips = tester
        .widgetList<NeumorphicIconButton>(find.byType(NeumorphicIconButton))
        .map((b) => b.tooltip);
    // Себе — изменить и сменить пароль; работнику — изменить, новый бейдж, заблокировать.
    expect(tooltips, [
      t.portal.users.edit,
      t.portal.users.newPassword,
      t.portal.users.edit,
      t.portal.users.newBadge,
      t.portal.users.block,
    ]);
  });

  testWidgets(
    'новый по бейджу — запрос с бейджем и должностью; отказ — текстом',
    (tester) async {
      when(() => repo.createUser(any())).thenAnswer(
        (_) async => const Left(
          Failure.server(409, 'бейдж уже выдан другому пользователю'),
        ),
      );
      await pump(tester);

      await tester.tap(find.text(t.portal.users.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Пётр Новый');
      await tester.enterText(find.byType(TextField).at(1), '5500000212345678');
      await tester.tap(find.text(t.portal.users.create));
      await tester.pumpAndSettle();

      final draft =
          verify(() => repo.createUser(captureAny())).captured.single
              as UserDraft;
      expect(draft.fullName, 'Пётр Новый');
      expect(draft.positionId, 'pw'); // по умолчанию — первая не системная
      expect(draft.badge, '5500000212345678');
      expect(draft.username, isNull);
      expect(find.text('бейдж уже выдан другому пользователю'), findsOneWidget);
    },
  );

  testWidgets('заблокировать — запрос и счётчик правок', (tester) async {
    when(
      () => repo.updateUser('ivan', isActive: false),
    ).thenAnswer((_) async => const Right(null));
    await pump(tester);
    final before = changes.value;

    await tester.tap(find.byTooltip(t.portal.users.block));
    await tester.pumpAndSettle();
    verify(() => repo.updateUser('ivan', isActive: false)).called(1);
    expect(changes.value, before + 1);
  });

  testWidgets('на узком экране без переполнения', (tester) async {
    await pump(tester, width: 360, textScale: 0.7);
    expect(tester.takeException(), isNull);
  });
}
