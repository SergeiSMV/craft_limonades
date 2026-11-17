import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../auth/token_storage.dart';
import '../database/app_database.dart';
import 'app_config.dart';

/// Переключение ТСД между рабочим сервером и демо-сервером (ADHOC-67).
///
/// Что: запоминает режим и перезапускает приложение.
/// Зачем перезапуск, а не замена адреса на ходу: от режима зависят адрес API, файл локальной
///      базы и ключи сессии, а их держат синглтоны - очередь, движок синхронизации, Dio, сканер.
///      Пересобрать их на ходу значит рисковать операцией, ушедшей не на тот сервер; новый
///      процесс собирает всё заново по сохранённому режиму.
/// Как: режим - файл `app_mode` в каталоге документов приложения (читается до сборки
///      зависимостей в `main`), перезапуск - платформенный канал `craft_wms/app` в
///      `MainActivity`. Не secure storage: на Android он пишет на диск в фоне
///      (`SharedPreferences.apply`), а перезапуск завершает процесс сразу - запись режима
///      терялась, и ТСД возвращался на рабочий вход. Файл пишется с `flush` до перезапуска;
///      секрета в режиме нет.
///      Вход в демо стирает демо-базу и демо-сессию: демо-сервер сбрасывается каждую ночь,
///      и вчерашние справочники и очередь там уже ничему не соответствуют.
///      Рабочая база и рабочая сессия при этом не трогаются.
abstract final class AppModeSwitch {
  static const _fileName = 'app_mode';
  static const _channel = MethodChannel('craft_wms/app');

  /// Прочитать режим до сборки зависимостей. Демо без адреса в сборке - рабочий режим.
  static Future<void> load() async {
    if (!AppConfig.demoAvailable) return;
    final file = await _modeFile();
    final raw = await file.exists() ? (await file.readAsString()).trim() : null;
    AppConfig.mode = raw == AppMode.demo.name ? AppMode.demo : AppMode.work;
  }

  /// Войти в демо-режим: чистая демо-база и сессия, режим, перезапуск.
  static Future<void> enterDemo() async {
    await _deleteDemoDatabase();
    await SecureTokenStorage.clearDemo();
    await _writeMode(AppMode.demo);
    await _restart();
  }

  /// Вернуться к рабочему серверу: его база и сессия ждут на месте.
  static Future<void> leaveDemo() async {
    await _writeMode(AppMode.work);
    await _restart();
  }

  /// Файл режима в каталоге документов приложения.
  static Future<File> _modeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Записать режим сразу на диск: следом процесс завершается без уборки.
  static Future<void> _writeMode(AppMode mode) async {
    final file = await _modeFile();
    await file.writeAsString(mode.name, flush: true);
  }

  /// Файл демо-базы и его спутники журнала. Путь - как у drift_flutter по умолчанию:
  /// каталог документов приложения и `<имя>.sqlite`.
  static Future<void> _deleteDemoDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final base = '${dir.path}/${AppDatabase.demoFileName}.sqlite';
    for (final path in [base, '$base-wal', '$base-shm', '$base-journal']) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  /// Перезапуск процесса приложения (Android): новый процесс читает режим заново.
  static Future<void> _restart() => _channel.invokeMethod<void>('restart');
}
