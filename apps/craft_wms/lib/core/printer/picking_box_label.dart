import '../load_unit/load_unit_code.dart';
import 'cp1251.dart';
import 'good_label.dart';
import 'label_geometry.dart';
import 'label_language.dart';

/// Ярлык короба отгрузки заказа сборки (P9-07): QR короба и шапка заказа.
///
/// Что: слева сверху QR в формате ГЕ (`CWLU1:<uuid>`) - его сканируют на отгрузке, справа от
/// него номер сборки, накладная, заказ, дата и «Короб N из M»; под QR во всю ширину - клиент,
/// направление и адрес.
/// Зачем QR в формате ГЕ: короб отгрузки - грузовая единица, ТСД узнаёт его тем же разбором,
/// что короба приёмки. Вес не печатается: источника веса единицы нет (долг 36).
/// Как: строки приходят готовыми, с подписями (каждый факт своей строкой: «Накладная: …») -
/// подписи живут в i18n экрана, а ярлык только раскладывает их. Текст из реестра проходит
/// `sanitizeTsplText`: кавычка в адресе обрезала бы команду TSPL молча.
///
/// ⚠ Раскладка рассчитана на рулон 58×40 мм по ширине шрифтов из спецификации; реальную
/// ширину кириллицы подтверждать печатью (правило P4-08).
class PickingBoxLabel {
  const PickingBoxLabel({
    required this.loadUnitId,
    required this.title,
    required this.side,
    required this.boxLine,
    required this.body,
  });

  /// Короб отгрузки (UUID) - уезжает в QR.
  final String loadUnitId;

  /// Номер сборки крупно: «СБ-000123».
  final String title;

  /// Строки справа от QR: накладная, заказ, дата.
  final List<String> side;

  /// «Короб 1 из 3» - крупно под строками справа.
  final String boxLine;

  /// Строки под QR во всю ширину: клиент, направление, адрес.
  final List<String> body;

  static const int _margin = 16;

  /// Модуль QR в точках: 5 даёт код около 18 мм - короб сканируют с руки, а место нужно
  /// шапке заказа. Сторона - 29 модулей (полезная нагрузка постоянна, как у ярлыка ГЕ).
  static const int _qrCell = 5;
  static const int _qrModules = 29;
  static const int _gap = 12;

  /// Шрифт строк - «2» (12×20, по спецификации), крупный - «3» (16×24).
  static const String _font = '2';
  static const int _charWidth = 12;
  static const int _lineHeight = 24;
  static const String _bigFont = '3';
  static const int _bigCharWidth = 16;
  static const int _bigLineHeight = 28;

  /// Строк адреса под QR: остальное - многоточием.
  static const int _bodyLines = 4;

  /// Команды TSPL ярлыка.
  List<int> tspl(LabelGeometry geometry) {
    final qrSide = _qrModules * _qrCell;
    final sideLeft = _margin + qrSide + _gap;
    final sideChars = (geometry.widthDots - sideLeft - _margin) ~/ _charWidth;
    final bigChars = (geometry.widthDots - sideLeft - _margin) ~/ _bigCharWidth;
    final bodyChars = (geometry.widthDots - _margin * 2) ~/ _charWidth;

    final out = <int>[
      ...encodeCommands(
        'SIZE ${_mm(geometry.widthMm)} mm,${_mm(geometry.heightMm)} mm\r\n'
        'GAP ${_mm(geometry.gapMm)} mm,0 mm\r\n'
        'DIRECTION 1\r\n'
        'CLS\r\n'
        'CODEPAGE 1251\r\n'
        'QRCODE $_margin,$_margin,M,$_qrCell,A,0,"${encodeLoadUnitPayload(loadUnitId)}"\r\n',
      ),
    ];

    void text(int x, int y, String font, String value) {
      out
        ..addAll(encodeCommands('TEXT $x,$y,"$font",0,1,1,"'))
        ..addAll(encodeCp1251(sanitizeTsplText(value)))
        ..addAll(encodeCommands('"\r\n'));
    }

    var y = _margin;
    text(sideLeft, y, _bigFont, _cut(title, bigChars));
    y += _bigLineHeight;
    for (final s in side) {
      text(sideLeft, y, _font, _cut(s, sideChars));
      y += _lineHeight;
    }
    text(sideLeft, y, _bigFont, _cut(boxLine, bigChars));

    // Под QR - клиент, направление, адрес: длинное переносится, лишнее - многоточием.
    y = _margin + qrSide + _gap ~/ 2;
    final lines = <String>[
      for (final b in body)
        ...wrapLabelText(b, perLine: bodyChars, maxLines: 2),
    ].take(_bodyLines);
    for (final l in lines) {
      text(_margin, y, _font, l);
      y += _lineHeight;
    }
    return out..addAll(encodeCommands('PRINT 1,1\r\n'));
  }

  /// Строка, урезанная до [chars] знаков с многоточием.
  static String _cut(String s, int chars) =>
      s.length <= chars ? s : '${s.substring(0, chars - 1)}…';
}

/// Размер в формате TSPL: целые без хвостового нуля.
String _mm(double value) => value == value.roundToDouble()
    ? '${value.round()}'
    : value.toStringAsFixed(1);
