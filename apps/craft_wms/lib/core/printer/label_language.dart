import 'dart:convert';

import 'cp1251.dart';
import 'label_geometry.dart';

/// Язык команд принтера этикеток (P4-05).
///
/// Зачем интерфейс: язык — отдельное решение от транспорта. Принтер XP-P323B понимает несколько
/// языков сразу, и какой из них примет конкретный экземпляр, выясняется печатью. Проверка на
/// живом устройстве показала, что TSPL он принимает, несмотря на заводской режим `EZD` на
/// дисплее; ZPL остался реализованным — следующий принтер может оказаться другим.
///
/// ⚠ Тестовая этикетка намеренно **латиницей**. Встроенные шрифты этих принтеров кириллицу
/// отдают не всегда, и провал печати из-за шрифта был бы неотличим от провала транспорта.
/// Кириллица на ярлыке ГЕ — вопрос `P4-06`.
abstract interface class LabelLanguage {
  /// Короткий идентификатор для хранения выбора и для логов.
  String get id;

  /// Как язык называется человеку.
  String get title;

  /// Тестовая этикетка: доказывает, что команды дошли и принтер их понял.
  List<int> testLabel(LabelGeometry geometry);

  /// Диагностика кириллицы: печатает одну и ту же русскую строку всеми встроенными шрифтами.
  ///
  /// Зачем: по документации вопрос не решается. Встроенные шрифты принтеров этого класса
  /// кириллицу обычно не содержат, но XP-P323B продаётся как русифицированный, а TSPL умеет
  /// `CODEPAGE 1251`. Одна этикетка со всеми шрифтами сразу отвечает на вопрос, какой из них
  /// годится, — и отвечает быстрее, чем переписка с производителем.
  List<int> cyrillicProbe(LabelGeometry geometry);

  /// Калибровка датчика промежутка под заправленный рулон.
  ///
  /// Зачем отдельной командой: принтер не знает, что в него заправлено. Пока он не измерил
  /// рулон, после печати он ищет промежуток там, где ему объявили, и промахивается — выдаёт
  /// лишнюю пустую этикетку или мотает ленту до упора. Калибровка делается один раз на рулон
  /// и сама прогоняет пару этикеток: это не брак, а измерение.
  List<int> calibrate(LabelGeometry geometry);
}

/// Байты команд. Кодировка — latin1: команды состоят из ASCII, и UTF-8 здесь дал бы
/// многобайтовые последовательности там, где принтер ждёт один байт на символ.
List<int> encodeCommands(String commands) => latin1.encode(commands);

/// Размер в формате TSPL: число с одним знаком после запятой, без хвостового нуля у целых.
String _mm(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);

/// TSPL — «родной» язык принтеров этого класса (TSC-совместимый).
///
/// Координаты в точках, размер этикетки — в миллиметрах: в этих единицах его проще сверить
/// с рулоном в руках.
class TsplLanguage implements LabelLanguage {
  const TsplLanguage();

  @override
  String get id => 'tspl';

  @override
  String get title => 'TSPL';

  /// Объявление рулона — общее начало и печати, и калибровки.
  String _setup(LabelGeometry g) =>
      'SIZE ${_mm(g.widthMm)} mm,${_mm(g.heightMm)} mm\r\n'
      'GAP ${_mm(g.gapMm)} mm,0 mm\r\n';

  @override
  List<int> testLabel(LabelGeometry geometry) => encodeCommands(
    '${_setup(geometry)}'
    'DIRECTION 1\r\n'
    'CLS\r\n'
    'TEXT 24,24,"3",0,1,1,"CRAFT WMS"\r\n'
    'TEXT 24,72,"2",0,1,1,"TSPL test label"\r\n'
    'BAR 24,120,400,3\r\n'
    'TEXT 24,140,"2",0,1,1,"P4-05 printer driver"\r\n'
    'PRINT 1,1\r\n',
  );

  @override
  List<int> calibrate(LabelGeometry geometry) => encodeCommands(
    // Размер объявляем перед измерением: GAPDETECT отталкивается от него, а не гадает с нуля.
    '${_setup(geometry)}'
    'GAPDETECT\r\n',
  );

  /// Встроенные шрифты TSPL, которые имеет смысл проверять на кириллицу.
  ///
  /// «1»…«5» — растровые шрифты фиксированного размера, они есть у всех принтеров этого класса.
  /// «0» — масштабируемый TrueType у моделей с движком TSPL-EZ; если он есть и знает кириллицу,
  /// это лучший вариант для ярлыка: размер задаётся свободно.
  static const List<String> _fonts = ['1', '2', '3', '4', '5', '0'];

  @override
  List<int> cyrillicProbe(LabelGeometry geometry) {
    final out = <int>[];
    out.addAll(encodeCommands('${_setup(geometry)}DIRECTION 1\r\nCLS\r\n'));
    // Кодовая страница объявляется до текста: после неё принтер трактует байты как CP1251.
    out.addAll(encodeCommands('CODEPAGE 1251\r\n'));
    var y = 16;
    for (final font in _fonts) {
      // Имя шрифта латиницей рядом с русской строкой: если кириллица не вышла, по строке всё
      // равно видно, какой шрифт пробовали, — пустая строка сама по себе ничего не сказала бы.
      out.addAll(encodeCommands('TEXT 16,$y,"$font",0,1,1,"'));
      out.addAll(encodeCp1251('F$font АБВ абв ЁЖЗ 123'));
      out.addAll(encodeCommands('"\r\n'));
      y += 34;
    }
    out.addAll(encodeCommands('PRINT 1,1\r\n'));
    return out;
  }
}

/// ZPL — язык Zebra; у этого принтера он входит в заводской режим `EZD`.
///
/// Размеры в точках: ZPL не понимает миллиметры, поэтому пересчёт здесь, а не в голове
/// у читателя (203 dpi — 8 точек на мм).
class ZplLanguage implements LabelLanguage {
  const ZplLanguage();

  @override
  String get id => 'zpl';

  @override
  String get title => 'ZPL';

  @override
  List<int> testLabel(LabelGeometry geometry) => encodeCommands(
    '^XA\r\n'
    '^PW${geometry.widthDots}\r\n'
    '^LL${geometry.heightDots}\r\n'
    '^FO24,24^A0N,44,44^FDCRAFT WMS^FS\r\n'
    '^FO24,88^A0N,30,30^FDZPL test label^FS\r\n'
    '^FO24,136^GB400,3,3^FS\r\n'
    '^FO24,152^A0N,30,30^FDP4-05 printer driver^FS\r\n'
    '^XZ\r\n',
  );

  @override
  // ~JC — калибровка датчика носителя. Как и в TSPL, прогоняет несколько этикеток.
  List<int> calibrate(LabelGeometry geometry) => encodeCommands('~JC\r\n');

  @override
  List<int> cyrillicProbe(LabelGeometry geometry) {
    final out = <int>[];
    out.addAll(
      encodeCommands(
        '^XA\r\n'
        '^PW${geometry.widthDots}\r\n'
        '^LL${geometry.heightDots}\r\n'
        // ^CI — набор символов. 27 — это CP1251 у совместимых прошивок.
        '^CI27\r\n'
        '^FO16,16^A0N,34,34^FD',
      ),
    );
    out.addAll(encodeCp1251('A0 АБВ абв ЁЖЗ 123'));
    out.addAll(encodeCommands('^FS\r\n^FO16,60^ADN,36,20^FD'));
    out.addAll(encodeCp1251('AD АБВ абв ЁЖЗ 123'));
    out.addAll(encodeCommands('^FS\r\n^XZ\r\n'));
    return out;
  }
}

/// Языки, между которыми выбирает человек на экране проверки принтера.
const List<LabelLanguage> kLabelLanguages = [TsplLanguage(), ZplLanguage()];

/// Язык по идентификатору; `null` — если сохранён идентификатор, которого больше нет.
LabelLanguage? labelLanguageById(String? id) {
  for (final language in kLabelLanguages) {
    if (language.id == id) return language;
  }
  return null;
}
