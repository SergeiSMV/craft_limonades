import 'dart:convert';

import 'package:craft_wms/core/auth/jwt.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разбор JWT на клиенте: единственный вопрос, на который он отвечает, - не истёк ли токен.
/// От этого зависит, пустит ли приложение работать без сети (P2-02).
void main() {
  /// Собрать токен с заданной полезной нагрузкой (подпись не важна - её клиент не проверяет).
  String token(Map<String, dynamic> claims) {
    String seg(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    return '${seg({'alg': 'HS256'})}.${seg(claims)}.signature';
  }

  final now = DateTime.utc(2026, 9, 2, 12);

  test('живой токен не считается истёкшим', () {
    final t = token({
      'exp': now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000,
    });
    expect(JwtPayload.tryParse(t)!.isExpired(now: now), isFalse);
  });

  test('просроченный токен считается истёкшим', () {
    final t = token({
      'exp': now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
    });
    expect(JwtPayload.tryParse(t)!.isExpired(now: now), isTrue);
  });

  test('токен без exp считается истёкшим', () {
    // Бессрочный доступ на устройстве, которое может потеряться, разрешать по умолчанию нельзя.
    expect(JwtPayload.tryParse(token({'sub': 'u1'}))!.isExpired(now: now), isTrue);
  });

  test('мусор вместо токена не роняет разбор', () {
    expect(JwtPayload.tryParse('не-токен'), isNull);
    expect(JwtPayload.tryParse('a.b.c'), isNull);
    expect(JwtPayload.tryParse(''), isNull);
  });

  test('читает роль и субъект из полезной нагрузки', () {
    final t = token({'sub': 'u1', 'role': 'admin', 'exp': 1});
    expect(JwtPayload.tryParse(t)!.claims['role'], 'admin');
  });
}
