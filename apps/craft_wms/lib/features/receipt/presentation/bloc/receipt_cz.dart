import '../../../cz/domain/cz_scan.dart';
import '../../../stock/data/catalog_models.dart';
import 'receipt_models.dart';

/// Марки «Честного знака» в приёмке (CZ-05): чистые правила без состояния — из ответа скана
/// в строки приёмки и раскладка марок по строкам. Вынесены из cubit, чтобы проверяться без него.

/// Положить марки в строки: совпавшая грань (товар, партия, короб, ячейка) получает марки и
/// столько же единиц, иначе — новая строка. [cell] — ячейка короба или текущая.
List<ReceiptLineDraft> mergeCzMarks(
  List<ReceiptLineDraft> current,
  List<ReceiptCzLine> add, {
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

/// Упаковки приёмки без тех, что лежат (через другие упаковки) в коробе ЧЗ [boxCode]:
/// удалённый короб уходит вместе со своими упаковками.
List<ReceiptCzGroup> groupsOutsideBox(
  List<ReceiptCzGroup> groups,
  String boxCode,
) {
  final gone = {boxCode};
  var changed = true;
  while (changed) {
    changed = false;
    for (final g in groups) {
      if (!gone.contains(g.code) && gone.contains(g.parentCode)) {
        gone.add(g.code);
        changed = true;
      }
    }
  }
  return groups.where((g) => !gone.contains(g.code)).toList();
}

/// Строки приёмки из ответа скана: у марки — она сама, у упаковки — её состав по товару и
/// партии; упаковка каждой марки — из `parents` ответа (иначе сам сканированный код).
///
/// [goods] — товар справочника по GTIN; строки без товара или без даты производства не
/// собираются — экран проверяет это до вызова ([czScanGaps]).
List<ReceiptCzLine> czReceiptLines(CzScanResult scan, Map<String, Good> goods) {
  if (scan.kind == CzCodeKind.unit) {
    final good = goods[scan.gtin];
    final date = scan.producedDate;
    if (good == null || date == null) return const [];
    return [
      ReceiptCzLine(
        good: good,
        date: czDate(date),
        marks: [
          ReceiptMarkDraft(cis: scan.code, discrepancy: scan.discrepancy),
        ],
      ),
    ];
  }
  return [
    for (final l in scan.composition)
      if (goods[l.gtin] != null && l.producedDate != null)
        ReceiptCzLine(
          good: goods[l.gtin]!,
          date: czDate(l.producedDate!),
          marks: [
            for (final c in l.cis)
              ReceiptMarkDraft(
                cis: c,
                aggregateCode: scan.parents[c] ?? scan.code,
                discrepancy: l.discrepancy,
              ),
          ],
        ),
  ];
}

/// Упаковки приёмки из ответа скана. Короб ЧЗ сам упаковкой не числится — он ГЕ с кодом;
/// групповая упаковка, отсканированная целиком, — упаковка без родителя: её короба в
/// приёмке нет.
List<ReceiptCzGroup> czReceiptGroups(CzScanResult scan) => [
  if (scan.kind == CzCodeKind.group) ReceiptCzGroup(code: scan.code),
  for (final g in scan.groups)
    ReceiptCzGroup(code: g.code, parentCode: g.parentCode),
];

/// Чего не хватает, чтобы принять скан: GTIN без товара справочника (их ШК для привязки) и
/// единицы без даты производства — без неё не определить партию.
({List<String> unknownGtins, bool noDate}) czScanGaps(
  CzScanResult scan,
  Map<String, Good> goods,
) {
  if (scan.kind == CzCodeKind.unit) {
    return (
      unknownGtins: [
        if (scan.gtin != null && goods[scan.gtin] == null) scan.gtin!,
      ],
      noDate: scan.producedDate == null,
    );
  }
  return (
    unknownGtins: {
      for (final l in scan.composition)
        if (goods[l.gtin] == null) l.gtin,
    }.toList(),
    noDate: scan.composition.any((l) => l.producedDate == null),
  );
}

/// Дата производства в виде строки приёмки — дд.мм.гггг.
String czDate(DateTime d) =>
    '${_two(d.day)}.${_two(d.month)}.${d.year.toString().padLeft(4, '0')}';

String _two(int v) => v.toString().padLeft(2, '0');

/// EAN-13 для привязки по GTIN-14: без ведущего нуля — так и обычный скан ШК той же бутылки
/// найдёт товар (то же правило, что у сервера в скане марки).
String ean13FromGtin(String gtin) =>
    gtin.length == 14 && gtin.startsWith('0') ? gtin.substring(1) : gtin;
