import 'cp1251.dart';
import 'label_geometry.dart';
import 'label_language.dart';

/// Товарный ярлык: штрихкод и наименование (P4-08).
///
/// Что: наклейка, которую клеят на товар - сам ШК в виде полос, его цифры под ними и
/// наименование сверху.
/// Зачем: двум разным нуждам. Товару без штрихкода выдали внутренний код (P4-07) - его нужно
/// на товар нанести. У товара со своим кодом наклейка могла стереться или порваться - тогда
/// печатается такая же взамен.
///
/// Наименование здесь не украшение: без него наклейка анонимна, и кладовщик, глядя на коробку,
/// не отличит один белый прямоугольник от другого, пока не отсканирует.
class GoodLabel {
  const GoodLabel({required this.barcode, required this.goodName});

  /// Штрихкод - то, что станет полосами и цифрами под ними.
  final String barcode;

  /// Наименование товара, как оно пришло из 1С.
  final String goodName;

  /// Отступ от края этикетки: 3 мм при 203 dpi.
  ///
  /// Больше, чем у ярлыка ГЕ: там по краям стоит QR, у которого своя белая зона, а здесь
  /// к самому краю подходит текст, и подача гуляет. Поля заодно оставляют запас на случай,
  /// если ширина символа окажется чуть больше измеренной.
  static const int _margin = 24;

  /// Шрифт наименования - «2» (12×20 точек).
  ///
  /// ⚠ Шрифт «5» для текста брать нельзя: он печатает строчные заглавными (снято с живого
  /// принтера, P4-06). «2» - компромисс между читаемостью и тем, сколько символов влезет:
  /// наименования из 1С длинные.
  static const String _nameFont = '2';

  /// Ширина символа шрифта «2» в точках - ИЗМЕРЕНА на печати, а не взята из спецификации.
  ///
  /// ⚠ В спецификации TSPL шрифт «2» описан как 12×20, и первая версия шаблона считала по 12.
  /// На живой печати строка из 30 знаков заняла почти все 58 мм - это около 15 точек на символ.
  /// Из-за заниженной метрики строка уезжала за край, и остаток названия срезало молча.
  ///
  /// Значение округлено вверх: ошибиться в большую сторону значит напечатать строку короче,
  /// ошибиться в меньшую - потерять хвост за краем этикетки. Цена этих ошибок разная.
  static const int _nameCharWidth = 15;

  static const int _nameLineHeight = 20;

  /// Сколько строк наименования печатаем.
  ///
  /// Четыре: по 36 знаков в строке это 144 символа - столько покрывает наименования из 1С,
  /// где к названию товара дописаны фасовка, сорт и торговая марка. Печатаются только занятые
  /// строки, поэтому короткому наименованию запас ничего не стоит.
  ///
  /// Высота проверена тестом: четыре строки, штрихкод и цифры под ним помещаются в 40 мм.
  /// Больше брать нельзя - начнёт съедать полосы, а они здесь главное.
  static const int _nameLines = 4;

  /// Ширина узкого модуля штрихкода. При 3 точках EAN-13 (95 модулей) занимает 285 точек -
  /// около 36 мм, и сканер берёт его с мятой наклейки, а не только с ровной.
  static const int _narrowBar = 3;

  /// Высота полос в точках. 120 - это 15 мм: ниже сканеру тяжелее поймать код под углом.
  static const int _barHeight = 120;

  /// Тип штрихкода в терминах TSPL, выведенный из формы кода.
  ///
  /// Символика из справочника здесь намеренно не используется: она необязательна (`NULL`,
  /// если неизвестна) и заполняется людьми, а форма кода известна всегда и не врёт.
  /// EAN-13 и EAN-8 печатаются своими типами - принтер сам считает контрольную цифру и
  /// рисует характерные удлинённые разделители; всё остальное уходит в Code128, который
  /// кодирует любые символы.
  String get tsplType {
    final digitsOnly = RegExp(r'^\d+$').hasMatch(barcode);
    if (digitsOnly && barcode.length == 13) return 'EAN13';
    if (digitsOnly && barcode.length == 8) return 'EAN8';
    return '128';
  }

  /// Наименование, разбитое на строки по ширине этикетки.
  List<String> nameLines(LabelGeometry geometry) {
    final perLine = (geometry.widthDots - _margin * 2) ~/ _nameCharWidth;
    return wrapLabelText(goodName, perLine: perLine, maxLines: _nameLines);
  }

  /// Команды TSPL для печати ярлыка.
  List<int> tspl(LabelGeometry geometry) {
    final lines = nameLines(geometry);
    final out = <int>[];
    out.addAll(
      encodeCommands(
        'SIZE ${_mm(geometry.widthMm)} mm,${_mm(geometry.heightMm)} mm\r\n'
        'GAP ${_mm(geometry.gapMm)} mm,0 mm\r\n'
        'DIRECTION 1\r\n'
        'CLS\r\n'
        'CODEPAGE 1251\r\n',
      ),
    );
    // Наименование - единственное место ярлыка с кириллицей, поэтому текст уходит CP1251,
    // а команды вокруг него - латиницей.
    for (var i = 0; i < lines.length; i++) {
      final y = _margin + i * (_nameLineHeight + 4);
      out.addAll(encodeCommands('TEXT $_margin,$y,"$_nameFont",0,1,1,"'));
      // Кавычку в наименовании обязательно убрать: она закрыла бы команду раньше времени,
      // и принтер напечатал бы огрызок названия (найдено на живой печати).
      out.addAll(encodeCp1251(sanitizeTsplText(lines[i])));
      out.addAll(encodeCommands('"\r\n'));
    }

    // Штрихкод по центру: его ширина для EAN известна заранее (95 модулей), для Code128
    // зависит от содержимого - там выравниваем по левому краю, чтобы не промахнуться
    // вычислением, как это уже случилось с QR (ADHOC-17).
    final barcodeTop = _margin + lines.length * (_nameLineHeight + 4) + 12;
    final left = tsplType == '128'
        ? _margin
        : ((geometry.widthDots - 95 * _narrowBar) / 2).round().clamp(
            _margin,
            10000,
          );
    out.addAll(
      encodeCommands(
        // Параметр «2» у человекочитаемой подписи - цифры под полосами по центру.
        // Их печатает сам принтер: отдельной строкой текста они разъехались бы с кодом.
        'BARCODE $left,$barcodeTop,"$tsplType",$_barHeight,2,0,$_narrowBar,$_narrowBar,'
        '"$barcode"\r\n'
        'PRINT 1,1\r\n',
      ),
    );
    return out;
  }
}

/// Режет текст на строки по ширине этикетки.
///
/// Переносит по словам, а длинное слово рвёт жёстко - иначе наименование вроде
/// «Полуфабрикаты-замороженные» не влезло бы вовсе. Остаток, не поместившийся в отведённые
/// строки, обрезается многоточием: лучше укоротить видимо, чем молча потерять хвост.
List<String> wrapLabelText(
  String text, {
  required int perLine,
  required int maxLines,
}) {
  final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || perLine <= 0 || maxLines <= 0) return const [];

  final lines = <String>[];
  var rest = normalized;
  while (rest.isNotEmpty && lines.length < maxLines) {
    if (rest.length <= perLine) {
      lines.add(rest);
      // Остаток обнуляем явно: по нему ниже решается, нужно ли многоточие, и строка,
      // поместившаяся целиком, не должна выглядеть обрезанной.
      rest = '';
      break;
    }
    // Ищем пробел, по которому можно перенести, не разрывая слово.
    var cut = rest.lastIndexOf(' ', perLine);
    if (cut <= 0) cut = perLine; // слово длиннее строки - рвём жёстко
    lines.add(rest.substring(0, cut).trimRight());
    rest = rest.substring(cut).trimLeft();
  }
  // Не поместившееся помечаем многоточием на последней строке.
  if (rest.isNotEmpty && lines.isNotEmpty && lines.length == maxLines) {
    final last = lines.last;
    final room = perLine - 1;
    lines[lines.length - 1] = last.length <= room
        ? '$last…'
        : '${last.substring(0, room).trimRight()}…';
  }
  return lines;
}

/// Размер в формате TSPL: целые без хвостового нуля.
String _mm(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);
