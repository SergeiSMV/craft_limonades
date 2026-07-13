import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

/// Профиль текущего пользователя — ответ защищённого `GET /auth/me` (P0-04).
/// JsonKey мапит snake_case из JSON бэкенда на camelCase полей Dart.
@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    @JsonKey(name: 'user_id') required String userId,
    required String login,
    @JsonKey(name: 'full_name') required String fullName,
    required String role,
  }) = _Profile;

  factory Profile.fromJson(Map<String, dynamic> json) => _$ProfileFromJson(json);
}
