import 'code128.dart';

/// Этикетка на балку для образца в портале (ADHOC-57) — геометрия один в один с бэкендом
/// (`internal/labels/geometry.go`, `render.go`), а тот — с rack_labels. Все размеры — в мм.
///
/// Что: профиль балки, единый кегль набора и раскладка частей «код — адрес — стрелка».
/// Зачем: оператор видит, как ляжет адрес на этикетку и какой высоты будут буквы, до печати.
/// Как: ширина адреса считается по метрикам Helvetica-Bold (те же, что у core-шрифта PDF),
///      поэтому кегль совпадает с печатным.

/// Ширина рабочего поля листа и этикетки на балку: A4 без полей 10 мм.
const kLabelWidth = 190.0;
const _workHeight = 277.0;

/// Карточек на стойку на листе A4 (95 × 277 мм, две колонки).
const kSideCardsPerSheet = 2;

/// Высота прописной Helvetica-Bold к кеглю.
const _capRatio = 0.718;

/// Пункт в мм: шаг уменьшения кегля, когда адрес не влезает.
const _pt = 25.4 / 72;

/// Меньше кегль адреса не уменьшается — тогда «не влезает» (`minFontPt` бэкенда).
const _minFont = 1 * _pt;

/// Ширины символов ASCII 32…126 Helvetica-Bold на 1000 единиц кегля (метрики core-шрифта PDF,
/// взяты из fpdf бэкенда). Символ вне таблицы — шириной «M».
// dart format off
const _helveticaBold = <int>[
  278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
  975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
  333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
  611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
];
// dart format on

/// Ширина строки при кегле 1 мм.
double textEm(String text) {
  var sum = 0;
  for (final r in text.runes) {
    final i = r - 32;
    sum += i >= 0 && i < _helveticaBold.length ? _helveticaBold[i] : 833;
  }
  return sum / 1000;
}

/// Профиль балки — large или small из config.yaml rack_labels.
class BeamProfile {
  const BeamProfile._({
    required this.rows,
    required this.pad,
    required this.gap,
    required this.capMax,
    required this.capMin,
    required this.module,
    required this.quiet,
    required this.barcodeHeight,
    required this.arrowWidth,
    required this.arrowHeight,
  });

  static const large = BeamProfile._(
    rows: 4,
    pad: 5,
    gap: 6,
    capMax: 26,
    capMin: 12,
    module: 0.30,
    quiet: 6,
    barcodeHeight: 26,
    arrowWidth: 22,
    arrowHeight: 26,
  );
  static const small = BeamProfile._(
    rows: 6,
    pad: 4,
    gap: 4,
    capMax: 16,
    capMin: 9,
    module: 0.28,
    quiet: 5,
    barcodeHeight: 16,
    arrowWidth: 14,
    arrowHeight: 16,
  );

  final int rows; // этикеток на листе
  final double pad; // внутреннее поле
  final double gap; // зазор между кодом, адресом и стрелкой
  final double capMax; // высота прописной, потолок
  final double capMin; // ниже — кегль уменьшается шагом 1 пт
  final double module; // ширина модуля штрих-кода
  final double quiet; // защитная зона кода с каждой стороны
  final double barcodeHeight;
  final double arrowWidth;
  final double arrowHeight;

  double get height => _workHeight / rows;

  /// Полная ширина кода с защитными зонами; адрес не кодируется — `null`.
  double? barcodeWidth(String value) {
    final n = code128Modules(value);
    return n == null ? null : n * module + 2 * quiet;
  }
}

/// Этикетка набора для подбора кегля: адрес и есть ли стрелка.
typedef BeamItem = ({String address, bool floor});

/// Единый кегль набора: кегль (мм), высота прописной и влезает ли адрес.
class BeamFont {
  const BeamFont({required this.size, required this.fits});

  final double size;
  final bool fits;

  double get capHeight => size * _capRatio;
}

/// Единый кегль по набору этикеток одного размера и одного «со штрих-кодом / без»: по самому
/// широкому адресу; стрелка у кого-то в наборе отнимает место у всех. Как `beamSizes` бэкенда.
BeamFont beamFont(
  BeamProfile p,
  Iterable<BeamItem> set, {
  required bool barcode,
}) {
  var widest = '';
  var arrow = false;
  for (final c in set) {
    if (textEm(c.address) > textEm(widest)) widest = c.address;
    arrow = arrow || c.floor;
  }
  var avail = kLabelWidth - 2 * p.pad;
  if (arrow) avail -= p.arrowWidth + p.gap;
  if (barcode) avail -= (p.barcodeWidth(widest) ?? 0) + p.gap;
  return _fitSize(textEm(widest), avail, p);
}

/// Кегль строки шириной [em] (в кеглях) по месту [avail]: цель — потолок профиля, ужимается
/// ровно до места. Ниже `capMin` — от него вниз шагом 1 пт, пока не влезет. Как `fitSize`
/// бэкенда.
BeamFont _fitSize(double em, double avail, BeamProfile p) {
  var size = p.capMax / _capRatio;
  if (em * size > avail) size *= avail / (em * size);
  final floor = p.capMin / _capRatio;
  if (size >= floor - 1e-6) return BeamFont(size: size, fits: true);
  size = floor;
  while (em * size > avail + 1e-9 && size - _pt >= _minFont - 1e-9) {
    size -= _pt;
  }
  return BeamFont(size: size, fits: em * size <= avail + 1e-9);
}

/// Часть этикетки и её левый край по горизонтали.
enum BeamPart { barcode, text, arrow }

/// Раскладка этикетки: части слева направо с левым краем (мм от края этикетки) и шириной.
List<(BeamPart, double, double)> beamLayout(
  BeamProfile p,
  String address,
  double size, {
  required bool floor,
  required bool barcode,
}) {
  final textW = textEm(address) * size;
  final parts = <(BeamPart, double)>[
    if (barcode) (BeamPart.barcode, p.barcodeWidth(address) ?? 0),
    (BeamPart.text, textW),
    if (floor) (BeamPart.arrow, p.arrowWidth),
  ];
  var band = p.gap * (parts.length - 1);
  for (final part in parts) {
    band += part.$2;
  }
  // Три части — крайние прижаты к полям, адрес между ними (код и стрелка на одном месте у
  // всех этикеток стеллажа); две или одна — строка по центру.
  final justify = barcode && parts.length > 2;
  var x = justify ? p.pad : (kLabelWidth - band) / 2;
  final extra = justify
      ? (kLabelWidth - 2 * p.pad - band) / (parts.length - 1)
      : 0.0;
  final out = <(BeamPart, double, double)>[];
  for (final (kind, w) in parts) {
    out.add((kind, x, w));
    x += w + p.gap + extra;
  }
  return out;
}

/// Стрелка вниз «блоком» с центром (cx, cy): стержень 0,42 ширины и головка на 0,55 высоты,
/// как `drawArrow` бэкенда. Вершины по порядку обхода, мм.
List<(double, double)> arrowPolygon(double cx, double cy, double w, double h) {
  const shaft = 0.42, head = 0.55;
  final sw = w * shaft, top = cy - h / 2, bot = cy + h / 2, y = bot - h * head;
  return [
    (cx - sw / 2, top),
    (cx + sw / 2, top),
    (cx + sw / 2, y),
    (cx + w / 2, y),
    (cx, bot),
    (cx - w / 2, y),
    (cx - sw / 2, y),
  ];
}
