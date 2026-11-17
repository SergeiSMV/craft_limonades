/// Code128 набора B для образца этикетки (ADHOC-57) - тот же кодер, что у бэкенда
/// (`internal/labels/code128.go`) и у rack_labels (reportlab): старт B, символы, контрольный,
/// стоп. Ширина кода в модулях от него зависит, а с ней - кегль адреса на этикетке.
library;

/// Шаблоны символов 0…106: заглавная буква - штрих, строчная - пробел; буква - ширина в
/// модулях (A = 1 … D = 4).
// dart format off
const _patterns = <String>[
  'BaBbBb', 'BbBaBb', 'BbBbBa', 'AbAbBc', 'AbAcBb', 'AcAbBb', 'AbBbAc', 'AbBcAb',
  'AcBbAb', 'BbAbAc', 'BbAcAb', 'BcAbAb', 'AaBbCb', 'AbBaCb', 'AbBbCa', 'AaCbBb',
  'AbCaBb', 'AbCbBa', 'BbCbAa', 'BbAaCb', 'BbAbCa', 'BaCbAb', 'BbCaAb', 'CaBaCa',
  'CaAbBb', 'CbAaBb', 'CbAbBa', 'CaBbAb', 'CbBaAb', 'CbBbAa', 'BaBaBc', 'BaBcBa',
  'BcBaBa', 'AaAcBc', 'AcAaBc', 'AcAcBa', 'AaBcAc', 'AcBaAc', 'AcBcAa', 'BaAcAc',
  'BcAaAc', 'BcAcAa', 'AaBaCc', 'AaBcCa', 'AcBaCa', 'AaCaBc', 'AaCcBa', 'AcCaBa',
  'CaCaBa', 'BaAcCa', 'BcAaCa', 'BaCaAc', 'BaCcAa', 'BaCaCa', 'CaAaBc', 'CaAcBa',
  'CcAaBa', 'CaBaAc', 'CaBcAa', 'CcBaAa', 'CaDaAa', 'BbAdAa', 'DcAaAa', 'AaAbBd',
  'AaAdBb', 'AbAaBd', 'AbAdBa', 'AdAaBb', 'AdAbBa', 'AaBbAd', 'AaBdAb', 'AbBaAd',
  'AbBdAa', 'AdBaAb', 'AdBbAa', 'BdAbAa', 'BbAaAd', 'DaCaAa', 'BdAaAb', 'AcDaAa',
  'AaAbDb', 'AbAaDb', 'AbAbDa', 'AaDbAb', 'AbDaAb', 'AbDbAa', 'DaAbAb', 'DbAaAb',
  'DbAbAa', 'BaBaDa', 'BaDaBa', 'DaBaBa', 'AaAaDc', 'AaAcDa', 'AcAaDa', 'AaDaAc',
  'AaDcAa', 'DaAaAc', 'DaAcAa', 'AaCaDa', 'AaDaCa', 'CaAaDa', 'DaAaCa', 'BaAdAb',
  'BaAbAd', 'BaAbCb', 'BcCaAaB',
];
// dart format on

const _startB = 104;
const _stop = 106;

/// Коды символов адреса; символ вне ASCII 32…127 (кириллица) набором B не кодируется - `null`.
List<int>? _codes(String value) {
  final codes = [_startB];
  var sum = _startB;
  var pos = 0;
  for (final r in value.runes) {
    if (r < 32 || r > 127) return null;
    pos++;
    codes.add(r - 32);
    sum += (r - 32) * pos;
  }
  return codes
    ..add(sum % 103)
    ..add(_stop);
}

const _a = 0x61; // 'a'
const _upper = 0x20; // разница кодов строчной и заглавной латиницы

/// Ширина элемента шаблона в модулях: A/a = 1 … D/d = 4.
int _width(int unit) => (unit | _upper) - _a + 1;

/// Заглавная буква шаблона - штрих, строчная - пробел.
bool _isBar(int unit) => unit < _a;

/// Ширина кода в модулях без защитных зон; не кодируется - `null`.
int? code128Modules(String value) {
  final codes = _codes(value);
  if (codes == null) return null;
  var n = 0;
  for (final c in codes) {
    for (final u in _patterns[c].codeUnits) {
      n += _width(u);
    }
  }
  return n;
}

/// Штрихи кода: (начало, ширина) в модулях от первого штриха; не кодируется - пусто.
List<(int, int)> code128Bars(String value) {
  final codes = _codes(value);
  if (codes == null) return const [];
  final bars = <(int, int)>[];
  var x = 0;
  for (final c in codes) {
    for (final u in _patterns[c].codeUnits) {
      final w = _width(u);
      if (_isBar(u)) bars.add((x, w));
      x += w;
    }
  }
  return bars;
}
