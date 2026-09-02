import '../utils/barcode.dart';

/// Что именно отсканировали. Первый скан определяет ветку операции (доменное решение проекта:
/// QR → грузовая единица, EAN-13 → штучный товар), поэтому классификация — часть домена,
/// а не деталь конкретного экрана.
enum ScanKind {
  /// Штрихкод товара: EAN-8/EAN-13/ITF-14 и числовые Code128 из выгрузки 1С.
  good,

  /// Адрес ячейки — Code128 с этикетки, которую печатает сам WMS (P-FS-05).
  cell,

  /// Грузовая единица (ГЕ) — QR. Сама ГЕ появится в P4/P5; здесь только распознавание.
  cargoUnit,

  /// Форма кода ни на что не похожа — решает вызывающий экран.
  unknown,
}

/// Адрес ячейки: сегменты из букв/цифр через дефис — `M1-1-10-1`, `С-Н-П`.
///
/// Дефис и есть отличительный признак: штрихкод товара всегда сплошные цифры, поэтому пересечься
/// эти две формы не могут. Ячейка без дефиса в адресе даст [ScanKind.unknown] — экран отработает
/// её прежним путём (резолв адреса на сервере), просто без подсказки о типе кода.
final _cellAddress = RegExp(
  r'^[0-9A-Za-zА-Яа-яЁё]+(?:-[0-9A-Za-zА-Яа-яЁё]+)+$',
);

/// Схема символики по идентификатору AIM (ISO/IEC 15424): `]` + буква схемы + модификатор.
///
/// Буква стандартизована и одинакова у всех производителей сканеров, в отличие от вендорского
/// имени (`QRCode` у Urovo, `QR_CODE` у других), поэтому AIM — предпочтительный источник.
/// Известные буквы: `Q` — QR, `d` — DataMatrix (модификатор 2 = GS1, носитель кодов маркировки
/// «Честного знака»), `C` — Code128, `E` — EAN/UPC, `I` — ITF.
String? aimScheme(String? aim) {
  if (aim == null || aim.length < 2 || !aim.startsWith(']')) return null;
  return aim[1];
}

/// Распознаётся ли символика как QR по её имени.
///
/// Декодер DT50S отдаёт символику и именем (`QRCode`, `Code128`), и числом (31, 8) — мост
/// предпочитает имя. Числовые коды намеренно НЕ разбираем: у прошивок они расходятся, а угаданное
/// соответствие хуже отсутствующего — на нём молча ломается развилка «ГЕ или товар». Если прошивка
/// пришлёт только число, QR определится по формату полезной нагрузки, когда он будет задан в P4.
bool _isQrSymbology(String? symbology) {
  if (symbology == null) return false;
  final value = symbology.toUpperCase();
  return value.contains('QR');
}

/// Классификация скана по символике и форме кода.
///
/// Порядок проверок: AIM → имя символики → сплошные цифры → адрес ячейки. Символика идёт первой,
/// потому что это факт от драйвера, а форма кода — лишь догадка; AIM опережает имя как более
/// надёжный источник. Когда AIM пришёл, имени уже не верим: оно вендорское и может расходиться.
///
/// ⚠ Правило «QR → грузовая единица» временное и намеренно узкое: QR — универсальный носитель,
/// им кодируют что угодно (на проверке DT50S им оказалась ссылка на домофон). Когда в P4/P5 будет
/// задан формат полезной нагрузки ГЕ, распознавать её нужно по содержимому, а символику оставить
/// подсказкой. Коды маркировки «Честного знака» сюда не попадают — они в DataMatrix (AIM `]d2`),
/// а не в QR, но и их надо будет разбирать по структуре GS1, а не по символике.
ScanKind classifyScan(String raw, {String? symbology, String? aim}) {
  final value = raw.trim();
  if (value.isEmpty) return ScanKind.unknown;
  final scheme = aimScheme(aim);
  if (scheme != null) {
    if (scheme == 'Q') return ScanKind.cargoUnit;
  } else if (_isQrSymbology(symbology)) {
    return ScanKind.cargoUnit;
  }
  if (looksLikeBarcode(value)) return ScanKind.good;
  if (_cellAddress.hasMatch(value)) return ScanKind.cell;
  return ScanKind.unknown;
}

/// Распознанный скан: сам код и символика «как пришла от драйвера» (может отсутствовать —
/// в клавиатурном режиме символики нет в принципе).
class ScanCode {
  const ScanCode({required this.raw, this.symbology, this.aim});

  /// Код без обрамляющих пробелов — то, что реально несёт этикетка.
  final String raw;

  /// Тип символики в сыром виде (имя или числовой код прошивки), либо `null`.
  final String? symbology;

  /// Идентификатор символики по AIM (`]C0`, `]Q0`, `]d2`), либо `null`.
  final String? aim;

  /// Тип объекта, к которому относится код.
  ScanKind get kind => classifyScan(raw, symbology: symbology, aim: aim);

  @override
  String toString() =>
      'ScanCode($raw, aim: $aim, symbology: $symbology, kind: ${kind.name})';

  @override
  bool operator ==(Object other) =>
      other is ScanCode &&
      other.raw == raw &&
      other.symbology == symbology &&
      other.aim == aim;

  @override
  int get hashCode => Object.hash(raw, symbology, aim);
}
