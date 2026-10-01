/// Геометрия рулона этикеток (P4-05).
///
/// Зачем отдельной настройкой, а не константой в языке команд: принтер не знает, что в него
/// заправлено, — размер ему объявляют командой. Ошибись в высоте, и после печати он догонит
/// ленту до следующего промежутка: выедет вторая этикетка, пустая. Ошибись в промежутке —
/// датчик не найдёт зазор и промотает рулон целиком.
///
/// Рулон меняется вместе с задачей (ярлык ГЕ и ярлык ШК разного размера), поэтому значения
/// живут в настройках терминала, а не в коде.
class LabelGeometry {
  const LabelGeometry({
    required this.widthMm,
    required this.heightMm,
    required this.gapMm,
  });

  /// Ширина этикетки в миллиметрах — поперёк движения ленты.
  final double widthMm;

  /// Высота этикетки в миллиметрах — вдоль движения ленты. Именно её принтер отсчитывает
  /// при подаче, и именно она даёт лишнюю пустую этикетку, когда задана с запасом.
  final double heightMm;

  /// Промежуток между этикетками в миллиметрах — то, что ищет датчик.
  final double gapMm;

  /// Разрешение печатающей головки XP-P323B: 203 dpi — это ровно 8 точек на миллиметр.
  /// Нужно языкам, которые считают в точках (ZPL), а не в миллиметрах (TSPL).
  static const int dotsPerMm = 8;

  /// Ширина в точках — для языков, не понимающих миллиметры.
  int get widthDots => (widthMm * dotsPerMm).round();

  /// Высота в точках.
  int get heightDots => (heightMm * dotsPerMm).round();

  /// Умолчание до первой калибровки: распространённый размер этикетки 58 × 40 мм.
  /// Это догадка, а не измерение, — поэтому размер и вынесен в настройки.
  static const LabelGeometry fallback = LabelGeometry(
    widthMm: 58,
    heightMm: 40,
    gapMm: 2,
  );

  /// Разбор сохранённого значения вида `58x40x2`. Любая порча строки даёт [fallback]:
  /// печатать с умолчанием лучше, чем не печатать вовсе.
  static LabelGeometry parse(String? raw) {
    if (raw == null) return fallback;
    final parts = raw.split('x');
    if (parts.length != 3) return fallback;
    final values = parts.map(double.tryParse).toList();
    if (values.any((v) => v == null || v <= 0)) return fallback;
    return LabelGeometry(
      widthMm: values[0]!,
      heightMm: values[1]!,
      gapMm: values[2]!,
    );
  }

  /// Строка для хранения.
  String get stored =>
      '$widthMm'
      'x'
      '$heightMm'
      'x'
      '$gapMm';

  @override
  bool operator ==(Object other) =>
      other is LabelGeometry &&
      other.widthMm == widthMm &&
      other.heightMm == heightMm &&
      other.gapMm == gapMm;

  @override
  int get hashCode => Object.hash(widthMm, heightMm, gapMm);

  @override
  String toString() => 'LabelGeometry($widthMm x $heightMm, gap $gapMm)';
}
