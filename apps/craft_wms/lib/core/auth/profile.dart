import 'package:freezed_annotation/freezed_annotation.dart';

import 'rights.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

/// Профиль текущего пользователя - ответ защищённого `GET /auth/me` (P0-04).
/// JsonKey мапит snake_case из JSON бэкенда на camelCase полей Dart.
@freezed
abstract class Profile with _$Profile {
  const Profile._();

  const factory Profile({
    @JsonKey(name: 'user_id') required String userId,
    required String login,
    @JsonKey(name: 'full_name') required String fullName,
    required String role,

    /// Должность (ADHOC-49); пусто - сервер старше должностей.
    @Default('') String position,

    /// Действующие права должности (ADHOC-49).
    @Default(<String>[]) List<String> rights,
  }) = _Profile;

  factory Profile.fromJson(Map<String, dynamic> json) =>
      _$ProfileFromJson(json);

  /// Есть ли хоть одно из прав; право с точкой на конце - префикс: [Rights.portal] - любое
  /// право портала, [Rights.tsd] - любое на ТСД. Сервер без должностей прав не отдаёт - тогда
  /// по прежней роли: admin - всё, кладовщик - всё на ТСД.
  bool can(String right, [List<String> more = const []]) {
    final wanted = [right, ...more];
    if (position.isEmpty && rights.isEmpty) {
      return role == 'admin' || wanted.any((w) => w.startsWith(Rights.tsd));
    }
    return wanted.any(
      (w) => w.endsWith('.')
          ? rights.any((r) => r.startsWith(w))
          : rights.contains(w),
    );
  }
}
