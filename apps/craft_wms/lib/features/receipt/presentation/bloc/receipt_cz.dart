import '../../../cz/domain/cz_intake.dart';
import '../../../stock/data/catalog_models.dart';
import 'receipt_models.dart';

/// Марки «Честного знака» в приёмке (CZ-05): раскладка марок по строкам приёмки. Чтение ответа
/// скана в строки прихода — общее с «Вводом остатков» (`cz/domain/cz_intake.dart`).

/// Положить марки в строки: совпавшая грань (товар, партия, короб, ячейка) получает марки и
/// столько же единиц, иначе — новая строка. [cell] — ячейка короба или текущая.
List<ReceiptLineDraft> mergeCzMarks(
  List<ReceiptLineDraft> current,
  List<CzIntakeLine> add, {
  ReceiptBox? box,
  Cell? cell,
}) {
  final lines = List<ReceiptLineDraft>.from(current);
  for (final a in add) {
    if (a.marks.isEmpty) continue;
    final idx = lines.indexWhere(
      (l) => l.sameGrain(
        goodId: a.good.id,
        date: a.date,
        boxId: box?.id,
        cellId: cell?.id,
      ),
    );
    if (idx >= 0) {
      lines[idx] = lines[idx].copyWith(
        qty: lines[idx].qty + a.marks.length,
        marks: [...lines[idx].marks, ...a.marks],
      );
    } else {
      lines.add(
        ReceiptLineDraft(
          good: a.good,
          productionDate: a.date,
          qty: a.marks.length.toDouble(),
          boxId: box?.id,
          cell: cell,
          marks: a.marks,
        ),
      );
    }
  }
  return lines;
}
