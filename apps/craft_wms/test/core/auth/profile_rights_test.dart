import 'package:craft_wms/core/auth/profile.dart';
import 'package:craft_wms/core/auth/rights.dart';
import 'package:craft_wms/core/gen/strings.g.dart';
import 'package:flutter_test/flutter_test.dart';

/// ADHOC-50: права профиля из `/auth/me` — действия по разделам; префикс «portal.» / «tsd.» —
/// любое право приложения; сервер без должностей — по прежней роли.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocaleSettings.useDeviceLocale);

  Profile profile({
    String role = 'employee',
    String position = '',
    List<String> rights = const [],
  }) => Profile(
    userId: 'u1',
    login: '',
    fullName: 'Тест',
    role: role,
    position: position,
    rights: rights,
  );

  List<String> allCodes() => [for (final app in rightsTree()) ...app.codes];

  test(
    'действия — ровно те, что отдал сервер; префикс — любое право приложения',
    () {
      final p = Profile.fromJson({
        'user_id': 'u1',
        'login': '',
        'full_name': 'Офис',
        'role': 'employee',
        'position': 'Оператор',
        'rights': [Rights.problemsView, Rights.problemsResolve],
      });
      expect(p.position, 'Оператор');
      expect(p.can(Rights.problemsResolve), isTrue);
      expect(p.can(Rights.receiptView), isFalse);
      expect(p.can(Rights.receiptView, [Rights.problemsView]), isTrue);
      expect(p.can(Rights.portal), isTrue);
      expect(p.can(Rights.tsd), isFalse);
    },
  );

  test('должность без прав — ничего, даже при роли admin в токене', () {
    final p = profile(role: 'admin', position: 'Стажёр');
    expect(allCodes().any(p.can), isFalse);
    expect(p.can(Rights.portal), isFalse);
  });

  test('сервер без должностей: admin — всё, кладовщик — всё на ТСД', () {
    final admin = profile(role: 'admin');
    expect(allCodes().every(admin.can), isTrue);
    final worker = profile();
    expect(worker.can(Rights.tsdMovement), isTrue);
    expect(worker.can(Rights.portal), isFalse);
  });

  test('дерево: 32 действия без повторов, как на сервере', () {
    final codes = allCodes();
    expect(codes.length, 32);
    expect(codes.toSet().length, 32);
  });
}
