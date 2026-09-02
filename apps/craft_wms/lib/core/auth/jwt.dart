import 'dart:convert';

/// Разбор JWT на стороне клиента — только для одного вопроса: не истёк ли токен.
///
/// Что: достаёт `exp` из полезной нагрузки и сравнивает с текущим временем.
/// Зачем: без сети сервер не спросить, а решить «пускать ли в приложение» надо (P2-02,
///        офлайн-вход). Подпись клиент проверить не может — у него нет секрета.
/// Как: base64url-разбор средней части токена.
///
/// ⚠ Это НЕ проверка подлинности. Подделанный токен здесь пройдёт — но он же будет отвергнут
/// сервером на первом же запросе. Смысл проверки в другом: не пускать по заведомо протухшей
/// сессии и не показывать данные, срок доступа к которым истёк.
class JwtPayload {
  const JwtPayload(this.claims);

  final Map<String, dynamic> claims;

  /// Разобрать токен; `null` — не JWT или повреждён.
  static JwtPayload? tryParse(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decoded);
      return map is Map<String, dynamic> ? JwtPayload(map) : null;
    } catch (_) {
      return null;
    }
  }

  /// Момент истечения токена; `null` — в токене нет `exp`.
  DateTime? get expiresAt {
    final exp = claims['exp'];
    if (exp is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  }

  /// Истёк ли токен к моменту [now] (по умолчанию — сейчас).
  ///
  /// Токен без `exp` считаем истёкшим: бессрочный доступ на устройстве, которое может
  /// потеряться, — не то, что стоит разрешать по умолчанию.
  bool isExpired({DateTime? now}) {
    final exp = expiresAt;
    if (exp == null) return true;
    return !exp.isAfter((now ?? DateTime.now()).toUtc());
  }
}
