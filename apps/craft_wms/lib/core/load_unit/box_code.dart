import '../gen/strings.g.dart';
import '../printer/load_unit_label.dart';

/// Короткий код короба для человека (CZ-06).
///
/// Свой короб - код с QR-ярлыка WMS. У транспортного короба ЧЗ ярлыка WMS нет: его код -
/// последние восемь цифр SSCC с этикетки ЧЗ с пометкой «ЧЗ», чтобы кладовщик искал на коробе
/// нужную наклейку.
String boxCode(String loadUnitId, {String? czCode}) => czCode == null
    ? LoadUnitLabel(loadUnitId).shortCodeFormatted
    : t.czScan.boxCode(code: czBoxTail(czCode));

/// Последние восемь цифр кода короба ЧЗ (`00`+SSCC) группами по четыре - так их ищут глазами
/// на этикетке ЧЗ.
String czBoxTail(String czCode) {
  final tail = czCode.substring(czCode.length - 8);
  return '${tail.substring(0, 4)} ${tail.substring(4)}';
}
