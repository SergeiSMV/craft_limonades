import 'package:injectable/injectable.dart';

import '../database/app_database.dart';

/// Что терминал помнит про принтер между запусками (P4-05).
///
/// Зачем помнить: принтер на складе один и меняется редко. Заставлять кладовщика выбирать его
/// при каждом запуске значило бы добавлять шаг к каждой печати ярлыка.
@lazySingleton
class PrinterSettings {
  const PrinterSettings(this._db);

  final AppDatabase _db;

  static const String _addressKey = 'printer.address';
  static const String _nameKey = 'printer.name';
  static const String _languageKey = 'printer.language';
  static const String _geometryKey = 'printer.geometry';

  /// Адрес выбранного принтера или `null`, если его ещё не выбирали.
  Future<String?> address() => _read(_addressKey);

  /// Имя выбранного принтера - чтобы показать его человеку, не поднимая Bluetooth.
  Future<String?> name() => _read(_nameKey);

  /// Идентификатор выбранного языка команд.
  Future<String?> languageId() => _read(_languageKey);

  /// Запомнить принтер.
  Future<void> savePrinter({
    required String address,
    required String name,
  }) async {
    await _write(_addressKey, address);
    await _write(_nameKey, name);
  }

  /// Запомнить язык команд.
  Future<void> saveLanguage(String id) => _write(_languageKey, id);

  /// Размер заправленного рулона, как его сохранили.
  Future<String?> geometry() => _read(_geometryKey);

  /// Запомнить размер рулона.
  Future<void> saveGeometry(String value) => _write(_geometryKey, value);

  /// Забыть принтер - например, когда его заменили на другой.
  Future<void> forgetPrinter() async {
    await _delete(_addressKey);
    await _delete(_nameKey);
  }

  Future<String?> _read(String key) async {
    final row = await (_db.select(
      _db.deviceSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _write(String key, String value) => _db
      .into(_db.deviceSettings)
      .insertOnConflictUpdate(DeviceSetting(key: key, value: value));

  Future<void> _delete(String key) =>
      (_db.delete(_db.deviceSettings)..where((t) => t.key.equals(key))).go();
}
