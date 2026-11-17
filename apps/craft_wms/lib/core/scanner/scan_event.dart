import 'scan_code.dart';

/// Сырое событие от аппаратного сканера - ровно то, что прислал драйвер.
///
/// Зачем отдельно от [ScanCode]: набор extras у прошивок Urovo расходится, и когда код не
/// распознан, единственный способ понять почему - увидеть исходный интент целиком. На этом
/// построен диагностический экран сканера; рабочие экраны работают с [ScanCode].
class RawScanEvent {
  const RawScanEvent({
    required this.action,
    required this.extras,
    this.code,
    this.symbology,
    this.aim,
  });

  /// Действие интента (`android.intent.ACTION_DECODE_DATA` или собственное действие приложения).
  final String? action;

  /// Все extras интента в виде «ключ → человекочитаемое значение».
  final Map<String, String> extras;

  /// Полезная нагрузка, если мост сумел её достать из известных ключей.
  final String? code;

  /// Символика в сыром виде (вендорское имя или числовой код прошивки).
  final String? symbology;

  /// Идентификатор символики по AIM (`]C0`, `]Q0`, `]d2`) - переносимый между сканерами.
  final String? aim;

  /// Разобранное событие как доменный скан; `null` - если код достать не удалось.
  ScanCode? get scan => code == null
      ? null
      : ScanCode(raw: code!.trim(), symbology: symbology, aim: aim);

  /// Разбор ответа платформенного канала. Типы приводим руками: канал отдаёт
  /// `Map<Object?, Object?>`, а не типизированную карту.
  factory RawScanEvent.fromChannel(Map<Object?, Object?> data) {
    final extras = <String, String>{};
    final rawExtras = data['extras'];
    if (rawExtras is Map) {
      rawExtras.forEach((key, value) => extras['$key'] = '$value');
    }
    return RawScanEvent(
      action: data['action'] as String?,
      code: data['code'] as String?,
      symbology: data['symbology'] as String?,
      aim: data['aim'] as String?,
      extras: extras,
    );
  }
}

/// Результат опроса устройства: есть ли аппаратный сканер и по каким признакам это решено.
///
/// Признаки возвращаются полностью, а не одним флагом: по ним диагностический экран объясняет,
/// почему на конкретном устройстве сканер «есть» или «нет» - без этого разбирательство на складе
/// упирается в непрозрачное «да/нет».
class ScannerProbe {
  const ScannerProbe({
    required this.available,
    required this.packages,
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.device,
    required this.actions,
  });

  /// Итог: устройство считается ТСД со сканером.
  final bool available;

  /// Найденные пакеты штатного ПО сканера - признак, по которому и решается [available].
  final List<String> packages;

  /// Производитель и бренд расходятся (на DT50S - `UBX` и `UROVO`), поэтому показываем оба:
  /// на решение они не влияют, но без них непонятно, что за устройство в руках.
  final String manufacturer;
  final String brand;
  final String model;
  final String device;

  /// Действия интентов, которые слушает мост (что прописывать в настройках сканера).
  final List<String> actions;

  /// Устройство без аппаратного сканера - обычный смартфон/эмулятор/веб.
  static const ScannerProbe none = ScannerProbe(
    available: false,
    packages: [],
    manufacturer: '',
    brand: '',
    model: '',
    device: '',
    actions: [],
  );

  /// Разбор ответа платформенного канала.
  factory ScannerProbe.fromChannel(Map<Object?, Object?> data) => ScannerProbe(
    available: data['available'] as bool? ?? false,
    packages:
        (data['packages'] as List?)?.map((e) => '$e').toList() ?? const [],
    manufacturer: data['manufacturer'] as String? ?? '',
    brand: data['brand'] as String? ?? '',
    model: data['model'] as String? ?? '',
    device: data['device'] as String? ?? '',
    actions: (data['actions'] as List?)?.map((e) => '$e').toList() ?? const [],
  );
}
