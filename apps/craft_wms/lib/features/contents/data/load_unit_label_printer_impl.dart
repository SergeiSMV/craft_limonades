import 'package:injectable/injectable.dart';

import '../../../core/printer/printer_device.dart';
import '../../../core/printer/printer_service.dart';
import '../domain/load_unit_label_printer.dart';

/// Печать ярлыка короба через принтер терминала (P5-05-1).
///
/// Тот же ярлык и тот же вызов, что в приёмке: ярлык целиком определяется идентификатором
/// короба, и испорченную наклейку меняют на такую же. Пометки «ПРОБНАЯ» нет - это рабочая
/// наклейка, она поедет на коробе.
@LazySingleton(as: LoadUnitLabelPrinter)
class LoadUnitLabelPrinterImpl implements LoadUnitLabelPrinter {
  LoadUnitLabelPrinterImpl(this._printer);

  final PrinterService _printer;

  @override
  Future<String?> printLabel(String loadUnitId) async {
    try {
      await _printer.printLoadUnitLabel(loadUnitId);
      return null;
    } on PrinterFailure catch (e) {
      return e.userMessage;
    } catch (e) {
      return e.toString();
    }
  }
}
