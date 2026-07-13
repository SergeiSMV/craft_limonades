import 'package:injectable/injectable.dart';

/// Хранилище JWT-токенов. Абстракция, чтобы верхние слои не знали, где токены лежат.
///
/// В P0-05 — in-memory (реализация ниже). В P0-06 добавится реализация поверх
/// flutter_secure_storage, а эта останется для тестов.
abstract class TokenStorage {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<void> save({required String access, required String refresh});
  Future<void> saveAccess(String access);
  Future<void> clear();
}

/// In-memory реализация: токены живут в памяти процесса и сбрасываются при перезапуске.
/// Достаточно для скелета; постоянное хранилище — задача P0-06.
@LazySingleton(as: TokenStorage)
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
