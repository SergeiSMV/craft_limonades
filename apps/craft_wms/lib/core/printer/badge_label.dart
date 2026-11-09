import 'cp1251.dart';
import 'good_label.dart';
import 'label_geometry.dart';
import 'label_language.dart';

/// Бейдж сотрудника (ADHOC-65): ФИО, должность и штрихкод входа.
///
/// Что: сверху ФИО (до двух строк) и должность, ниже - Code128 из 16 цифр бейджа с цифрами
/// под полосами. Этот код сканирует экран входа ТСД.
/// Зачем Code128: номер - 16 цифр, EAN их не вмещает; цифры подряд принтер кодирует набором C
/// (по два знака в символе), и код выходит коротким. Полосы - по левому краю, как у товарного
/// ярлыка с Code128: ширину считает принтер, и центровка вычислением уже промахивалась
/// (ADHOC-17).
/// ФИО и должность проходят `sanitizeTsplText`: кавычка обрезала бы команду TSPL молча.
///
/// ⚠ Раскладка рассчитана на рулон 58×40 мм; ширина шрифта «2» - измеренная (15 точек, P4-08).
class BadgeLabel {
  const BadgeLabel({
    required this.number,
    required this.fullName,
    this.position,
  });

  /// 16 цифр бейджа - уезжают в штрихкод.
  final String number;

  final String fullName;

  /// Подпись под ФИО: «Должность: …»; null - без неё.
  final String? position;

  static const int _margin = 24;
  static const String _font = '2';
  /// Ширина символа шрифта «2» - измерена на печати (P4-08), а не 12 по спецификации.
  static const int _charWidth = 15;
  static const int _lineHeight = 24;
  static const int _nameLines = 2;

  /// Модуль Code128 и высота полос: 2 точки дают код около 31 мм - влезает с полями; 96 точек -
  /// 12 мм, бейдж сканируют с руки.
  static const int _narrowBar = 2;
  static const int _barHeight = 96;

  /// Строки текста над штрихкодом.
  List<String> textLines(LabelGeometry geometry) {
    final perLine = (geometry.widthDots - _margin * 2) ~/ _charWidth;
    return [
      ...wrapLabelText(fullName, perLine: perLine, maxLines: _nameLines),
      if (position case final p?)
        ...wrapLabelText(p, perLine: perLine, maxLines: 1),
    ];
  }

  /// Команды TSPL бейджа.
  List<int> tspl(LabelGeometry geometry) {
    final out = <int>[
      ...encodeCommands(
        'SIZE ${_mm(geometry.widthMm)} mm,${_mm(geometry.heightMm)} mm\r\n'
        'GAP ${_mm(geometry.gapMm)} mm,0 mm\r\n'
        'DIRECTION 1\r\n'
        'CLS\r\n'
        'CODEPAGE 1251\r\n',
      ),
    ];
    var y = _margin;
    for (final l in textLines(geometry)) {
      out
        ..addAll(encodeCommands('TEXT $_margin,$y,"$_font",0,1,1,"'))
        ..addAll(encodeCp1251(sanitizeTsplText(l)))
        ..addAll(encodeCommands('"\r\n'));
      y += _lineHeight;
    }
    // Параметр «2» - цифры под полосами по центру, их печатает сам принтер.
    out.addAll(
      encodeCommands(
        'BARCODE $_margin,${y + 12},"128",$_barHeight,2,0,$_narrowBar,$_narrowBar,'
        '"$number"\r\n'
        'PRINT 1,1\r\n',
      ),
    );
    return out;
  }
}

/// Размер в формате TSPL: целые без хвостового нуля.
String _mm(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);
