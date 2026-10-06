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

  /// Прочитать сохранённый профиль (null — не сохранён).
  Future<String?> readProfile();

  /// Сохранить профиль (JSON) — нужен для офлайн-входа.
  Future<void> saveProfile(String json);

  /// Момент последнего успешного обмена с сервером (null — не было ни одного).
  Future<DateTime?> readLastContact();

  /// Запомнить момент успешного обмена с сервером — по нему ограничен офлайн-вход (долг 9).
  Future<void> saveLastContact(DateTime at);

  /// Удалить токены, профиль и отметку последнего контакта (выход из аккаунта).
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

  /// Профиль вошедшего пользователя. Лежит здесь, а не в локальной базе: это данные
  /// сотрудника (ФИО, логин, роль), а база — открытый кэш справочников.
  static const _kProfile = 'profile';

  /// Момент последнего успешного обмена с сервером, ISO-8601 в UTC.
  static const _kLastContact = 'last_contact';

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
  Future<String?> readProfile() => _storage.read(key: _kProfile);

  @override
  Future<void> saveProfile(String json) =>
      _storage.write(key: _kProfile, value: json);

  @override
  Future<DateTime?> readLastContact() async {
    final raw = await _storage.read(key: _kLastContact);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  @override
  Future<void> saveLastContact(DateTime at) =>
      _storage.write(key: _kLastContact, value: at.toUtc().toIso8601String());

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kProfile);
    await _storage.delete(key: _kLastContact);
  }
}

/// In-memory реализация для unit-тестов (P0-08): токены живут в памяти процесса
/// и сбрасываются при перезапуске. В DI не регистрируется — на устройстве
/// работает [SecureTokenStorage]; тесты создают этот класс напрямую.
class InMemoryTokenStorage implements TokenStorage {
  String? _access;
  String? _refresh;
  String? _profile;
  DateTime? _lastContact;

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
  Future<String?> readProfile() async => _profile;

  @override
  Future<void> saveProfile(String json) async => _profile = json;

  @override
  Future<DateTime?> readLastContact() async => _lastContact;

  @override
  Future<void> saveLastContact(DateTime at) async => _lastContact = at;

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
    _profile = null;
    _lastContact = null;
  }
}
