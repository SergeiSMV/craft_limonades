import '../gen/strings.g.dart';

/// Bluetooth-устройство, пригодное на роль принтера этикеток (P4-05).
///
/// Имя может быть пустым: оно приходит от самого устройства и иногда не успевает прочитаться
/// при обнаружении. Адрес есть всегда - по нему и идёт подключение, и он же запоминается.
class PrinterDevice {
  const PrinterDevice({required this.address, required this.name});

  /// MAC-адрес - устойчивый идентификатор. Имя принтер может сменить, адрес остаётся.
  final String address;

  /// Имя, как его отдаёт устройство (напр. `XP-P323B`).
  final String name;

  /// Что показать человеку: имя, а при его отсутствии - адрес.
  String get title => name.isNotEmpty ? name : address;

  factory PrinterDevice.fromMap(Map<Object?, Object?> map) =>
      PrinterDevice(address: '${map['address']}', name: '${map['name'] ?? ''}');

  @override
  bool operator ==(Object other) =>
      other is PrinterDevice && other.address == address && other.name == name;

  @override
  int get hashCode => Object.hash(address, name);

  @override
  String toString() => 'PrinterDevice($title, $address)';
}

/// Состояние Bluetooth и соединения с принтером.
///
/// Разложено на признаки, а не сведено к «готов/не готов»: человеку на складе нужно знать,
/// что именно чинить - включить Bluetooth, выбрать принтер или подойти к нему ближе.
class PrinterStatus {
  const PrinterStatus({
    required this.supported,
    required this.enabled,
    required this.connected,
    this.address,
  });

  /// На устройстве вообще есть Bluetooth (на эмуляторе - нет).
  final bool supported;

  /// Адаптер включён.
  final bool enabled;

  /// Сокет с принтером открыт.
  final bool connected;

  /// Адрес принтера, с которым установлено соединение.
  final String? address;

  static const PrinterStatus none = PrinterStatus(
    supported: false,
    enabled: false,
    connected: false,
  );

  factory PrinterStatus.fromMap(Map<Object?, Object?> map) => PrinterStatus(
    supported: map['supported'] as bool? ?? false,
    enabled: map['enabled'] as bool? ?? false,
    connected: map['connected'] as bool? ?? false,
    address: map['address'] as String?,
  );

  @override
  String toString() =>
      'PrinterStatus(supported: $supported, enabled: $enabled, '
      'connected: $connected, address: $address)';
}

/// Отказ печати, который понятен человеку и различим для кода.
class PrinterFailure implements Exception {
  const PrinterFailure(this.kind, this.message);

  final PrinterFailureKind kind;

  /// Текст как есть - от Android или драйвера («Broken pipe», «read failed…»). Для журнала
  /// и экрана диагностики, не для кладовщика.
  final String message;

  /// Что сказать кладовщику: что случилось и что сделать (P6-04).
  ///
  /// Технический текст ему ничего не скажет - «Broken pipe» после выключенного принтера
  /// выглядел поломкой приложения. Отказы прав и спаривания и так сформулированы по-русски
  /// для человека, их текст остаётся.
  String get userMessage => switch (kind) {
    PrinterFailureKind.io => t.printer.notResponding,
    PrinterFailureKind.notSelected => t.printer.notSelected,
    PrinterFailureKind.bluetoothOff => t.printer.bluetoothOff,
    PrinterFailureKind.locationOff => t.printer.locationOff,
    PrinterFailureKind.unsupported => t.printer.unsupported,
    PrinterFailureKind.permission || PrinterFailureKind.pairing => message,
  };

  @override
  String toString() => 'PrinterFailure(${kind.name}: $message)';
}

/// Причина отказа. Граница проведена по тому, **кто и что должен сделать дальше**:
/// нехватку прав чинит человек в настройках, обрыв связи лечится повтором, отсутствие
/// Bluetooth не лечится вовсе.
enum PrinterFailureKind {
  /// Нет разрешения на Bluetooth или на поиск устройств.
  permission,

  /// Соединение не установилось или оборвалось: принтер выключен, далеко, занят.
  io,

  /// Спаривание не состоялось: не тот PIN, отмена, принтер занят другим хостом.
  /// Отдельно от [io], потому что чинится это иначе - через диалог спаривания или
  /// настройки Android, а не повтором подключения.
  pairing,

  /// На этом устройстве Bluetooth нет (эмулятор, веб).
  unsupported,

  /// Bluetooth выключен - включается в шторке.
  bluetoothOff,

  /// Выключена геолокация, без которой Android до 12 не ищет Bluetooth-устройства (ADHOC-20).
  /// Отдельно от [permission]: разрешение выдано, чинится это переключателем в шторке.
  locationOff,

  /// Принтер не выбран - выбирается в настройках печати, повтор не поможет.
  notSelected,
}
