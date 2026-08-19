import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';

/// Хранилище JWT-токенов. Абстракция, чтобы верхние слои не знали, где токены лежат.
///
/// Реализация по умолчанию — [SecureTokenStorage] поверх flutter_secure_storage
/// (Android Keystore). [InMemoryTokenStorage] оставлена для unit-тестов (P0-08),
/// где платформенное хранилище недоступно.
abstract class TokenStorage {
  /// Прочитать сохранённый access-токен (null — если не сохранён).
  Future<String?> readAccess();

  /// Прочитать сохранённый refresh-токен (null — если не сохранён).
  Future<String?> readRefresh();

  /// Сохранить пару токенов (перезаписывает предыдущие).
  Future<void> save({required String access, required String refresh});

  /// Обновить только access-токен (после refresh) — refresh не трогаем.
  Future<void> saveAccess(String access);

  /// Удалить оба токена (выход из аккаунта).
  Future<void> clear();
}

/// Реализация поверх flutter_secure_storage — токены в зашифрованном хранилище ОС.
///
/// Что: постоянно и безопасно хранит пару токенов между запусками приложения.
/// Зачем: кладовщик сканирует бейдж один раз — сессия должна пережить перезапуск ТСД,
///        при этом токены нельзя держать в открытом виде (иначе кража с устройства).
/// Как: на Android v10 плагин шифрует данные ключами из Keystore по умолчанию
///      (доп. настроек не требует).
@LazySingleton(as: TokenStorage)
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage() : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Ключи записей в хранилище.
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';

  @override
  Future<String?> readAccess() => _storage.read(key: _kAccess);

  @override
  Future<String?> readRefresh() => _storage.read(key: _kRefresh);

  @override
  Future<void> save({required String access, required String refresh}) async {
    // Пишем оба токена; порядок не критичен — читаем их независимо.
    await _storage.write(key: _kRefresh, value: refresh);
    await _storage.write(key: _kAccess, value: access);
  }

  @override
  Future<void> saveAccess(String access) =>
      _storage.write(key: _kAccess, value: access);

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }
}

/// In-memory реализация для unit-тестов (P0-08): токены живут в памяти процесса
/// и сбрасываются при перезапуске. В DI не регистрируется — на устройстве
/// работает [SecureTokenStorage]; тесты создают этот класс напрямую.
class InMemoryTokenStorage implements TokenStorage {
  String? _access;
  String? _refresh;

  @override
  Future<String?> readAccess() async => _access;

  @override
  Future<String?> readRefresh() async => _refresh;

  @override
  Future<void> save({required String access, required String refresh}) async {
    _access = access;
    _refresh = refresh;
  }

  @override
  Future<void> saveAccess(String access) async => _access = access;

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}
