import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:either_dart/either.dart';
import 'package:injectable/injectable.dart';

import '../constants/api_constants.dart';
import '../error/failure.dart';
import 'jwt.dart';
import 'profile.dart';
import 'token_storage.dart';

/// Репозиторий аутентификации: ходит на `/auth/*` и возвращает `Either<Failure, T>`.
/// Слой data чистой архитектуры — изолирует сеть от домена/UI.
@lazySingleton
class AuthRepository {
  AuthRepository(this._dio, this._storage);

  /// HTTP-клиент.
  final Dio _dio;

  /// Хранилище токенов.
  final TokenStorage _storage;

  /// Сколько после последнего успешного обмена с сервером терминал пускают без связи (долг 9).
  ///
  /// Сутки — решение заказчика: отозванный доступ перестаёт действовать на терминале не позже
  /// чем через 24 часа, а смена, начатая в мёртвой зоне после вчерашней работы, не встаёт.
  static const offlineLoginWindow = Duration(hours: 24);

  /// Вход по бейджу: `/auth/login` → сохраняем пару токенов → `/auth/me` → профиль.
  Future<Either<Failure, Profile>> login(String badge) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.loginByBadge,
        data: {'badge': badge},
      );
      final data = resp.data!;
      await _storage.save(
        access: data['access'] as String,
        refresh: data['refresh'] as String,
      );
      return me();
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Вход по логину/паролю: `/auth/login/password` → сохраняем токены → `/auth/me` → профиль.
  /// Путь для admin/оператора (веб-портал, смартфон); работник входит по бейджу через [login].
  Future<Either<Failure, Profile>> loginWithPassword(
    String username,
    String password,
  ) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        ApiConst.loginByPassword,
        data: {'username': username, 'password': password},
      );
      final data = resp.data!;
      await _storage.save(
        access: data['access'] as String,
        refresh: data['refresh'] as String,
      );
      return me();
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Вход на демо-сервере (ADHOC-67): `/auth/demo` без учётных данных → токены демо-
  /// пользователя → `/auth/me`. На рабочем сервере ручки нет — ответ 404, вход не проходит.
  Future<Either<Failure, Profile>> loginDemo() async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(ApiConst.loginDemo);
      final data = resp.data!;
      await _storage.save(
        access: data['access'] as String,
        refresh: data['refresh'] as String,
      );
      return me();
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Профиль текущего пользователя (защищённый `/auth/me`; access подставит интерсептор).
  /// Успешный ответ попутно сохраняем: он понадобится для входа без сети.
  /// Отметку контакта пишем здесь явно, а не полагаемся на интерсептор: тот пишет не чаще
  /// раза в минуту, и вход сразу после выхода (выход отметку стирает) остался бы без неё.
  Future<Either<Failure, Profile>> me() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(ApiConst.me);
      final profile = Profile.fromJson(resp.data!);
      await _storage.saveProfile(jsonEncode(resp.data));
      await _storage.saveLastContact(DateTime.now());
      return Right(profile);
    } on DioException catch (e) {
      return Left(_mapError(e));
    } catch (_) {
      return const Left(Failure.unknown());
    }
  }

  /// Сессия из локального хранилища — для входа без сети (P2-02).
  ///
  /// Что: отдаёт сохранённый профиль, если сессия ещё жива по сроку refresh-токена.
  /// Зачем: терминал, перезагруженный в зоне без Wi-Fi, иначе упирается в экран входа —
  ///        и весь офлайн-кэш становится недостижим.
  /// Как: срок берём из `exp` refresh-токена — именно он определяет, жива ли сессия;
  ///      access к этому моменту обычно уже истёк и будет обновлён при первой же связи.
  ///      Сверх того последний успешный обмен с сервером должен быть не старше
  ///      [offlineLoginWindow].
  ///
  /// `null` — сессии нет, срок вышел, связи не было дольше суток или профиль не сохранён.
  /// Во всех этих случаях нужен обычный вход.
  ///
  /// Зачем предел (долг 9): подпись токена клиент проверить не может, и запрос на отзыв
  /// доступа без связи не дойдёт. Без предела терминал с живым refresh-токеном работал бы
  /// до конца его срока — 30 дней; с ним отозванный доступ гаснет не позже чем через сутки.
  ///
  /// ⚠ Принятый риск: время берётся с часов терминала, и перевод их назад продлевает окно.
  /// Защититься от этого без сервера нельзя.
  ///
  /// Отметки контакта нет (приложение обновлено с версии без неё) — без связи не пускаем:
  /// первый же вход со связью её заведёт.
  Future<Profile?> offlineSession({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final refresh = await _storage.readRefresh();
    if (refresh == null) return null;
    final payload = JwtPayload.tryParse(refresh);
    if (payload == null || payload.isExpired(now: at)) return null;

    final lastContact = await _storage.readLastContact();
    if (lastContact == null) return null;
    if (at.difference(lastContact) > offlineLoginWindow) return null;

    final saved = await _storage.readProfile();
    if (saved == null) return null;
    try {
      return Profile.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Есть ли сохранённая сессия (токен в secure storage).
  /// Нужно для тихого восстановления при старте: без токенов сразу уходим на вход,
  /// не дёргая сеть.
  Future<bool> hasSession() async => (await _storage.readAccess()) != null;

  /// Выход — просто чистим токены.
  Future<void> logout() => _storage.clear();

  /// Маппинг ошибок dio в доменные Failure (что показать/как реагировать — решает bloc).
  Failure _mapError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 400) {
      return const Failure.auth('Неверный бейдж');
    }
    if (code != null) {
      return Failure.server(code);
    }
    return const Failure.network();
  }
}
