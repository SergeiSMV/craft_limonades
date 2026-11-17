import 'package:freezed_annotation/freezed_annotation.dart';

import '../../stock/domain/catalog_models.dart';
import 'cz_scan.dart';

part 'cz_intake.freezed.dart';
part 'cz_intake.g.dart';

/// Приход марок «Честного знака» - общее для приёмки (CZ-05) и «Ввода остатков» (ADHOC-46):
/// модели марки и упаковки в черновике и чистые правила «из ответа скана - в строки прихода».
/// Вынесено из приёмки, чтобы оба прихода читали ЧЗ одинаково и проверялись без экрана.

/// Марка «Честного знака» в строке прихода, как её прочитал скан.
///
/// [aggregateCode] - короб ЧЗ или групповая упаковка этого прихода, в которой марка пришла;
/// `null` - марка россыпью. [discrepancy] - расхождение с ЧЗ (`foreign_mark`, `retired`):
/// такая марка принимается, а сервер при проводке уводит её проблемой в «Изолятор».
@freezed
abstract class CzMarkDraft with _$CzMarkDraft {
  const factory CzMarkDraft({
    required String cis,
    String? aggregateCode,
    String? discrepancy,
  }) = _CzMarkDraft;

  factory CzMarkDraft.fromJson(Map<String, dynamic> json) =>
      _$CzMarkDraftFromJson(json);
}

/// Групповая упаковка ЧЗ прихода: из состава короба ЧЗ или отсканированная целиком.
/// [parentCode] - короб или упаковка этого же прихода; `null` - сама по себе.
@freezed
abstract class CzGroupDraft with _$CzGroupDraft {
  const factory CzGroupDraft({required String code, String? parentCode}) =
      _CzGroupDraft;

  factory CzGroupDraft.fromJson(Map<String, dynamic> json) =>
      _$CzGroupDraftFromJson(json);
}

/// Товар партии с марками ЧЗ, готовый лечь в приход: что прочитал скан, с товаром
/// справочника и датой производства единиц (дд.мм.гггг). Количество - число марок.
class CzIntakeLine {
  const CzIntakeLine({
    required this.good,
    required this.date,
    required this.marks,
  });

  final Good good;
  final String date;
  final List<CzMarkDraft> marks;
}

/// Чем закончилось добавление марок ЧЗ в приход.
enum CzIntakeAdd {
  /// Марки легли в приход.
  added,

  /// Короб или марка уже есть в этом приходе: второй раз одну бутылку не принять.
  duplicate,

  /// Короб ЧЗ закрыт: его состав - из ЧЗ, руками в него не добавляют.
  czBoxClosed,
}

/// Упаковки прихода без тех, что лежат (через другие упаковки) в коробе ЧЗ [boxCode]:
/// удалённый короб уходит вместе со своими упаковками.
List<CzGroupDraft> groupsOutsideBox(List<CzGroupDraft> groups, String boxCode) {
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

/// Строки прихода из ответа скана: у марки - она сама, у упаковки - её состав по товару и
/// партии; упаковка каждой марки - из `parents` ответа (иначе сам сканированный код).
///
/// [goods] - товар справочника по GTIN; строки без товара или без даты производства не
/// собираются - экран проверяет это до вызова ([czScanGaps]).
List<CzIntakeLine> czIntakeLines(CzScanResult scan, Map<String, Good> goods) {
  if (scan.kind == CzCodeKind.unit) {
    final good = goods[scan.gtin];
    final date = scan.producedDate;
    if (good == null || date == null) return const [];
    return [
      CzIntakeLine(
        good: good,
        date: czDate(date),
        marks: [CzMarkDraft(cis: scan.code, discrepancy: scan.discrepancy)],
      ),
    ];
  }
  return [
    for (final l in scan.composition)
      if (goods[l.gtin] != null && l.producedDate != null)
        CzIntakeLine(
          good: goods[l.gtin]!,
          date: czDate(l.producedDate!),
          marks: [
            for (final c in l.cis)
              CzMarkDraft(
                cis: c,
                aggregateCode: scan.parents[c] ?? scan.code,
                discrepancy: l.discrepancy,
              ),
          ],
        ),
  ];
}

/// Упаковки прихода из ответа скана. Короб ЧЗ сам упаковкой не числится - он ГЕ с кодом;
/// групповая упаковка, отсканированная целиком, - упаковка без родителя: её короба в
/// приходе нет.
List<CzGroupDraft> czIntakeGroups(CzScanResult scan) => [
  if (scan.kind == CzCodeKind.group) CzGroupDraft(code: scan.code),
  for (final g in scan.groups)
    CzGroupDraft(code: g.code, parentCode: g.parentCode),
];

/// Чего не хватает, чтобы принять скан: GTIN без товара справочника (их ШК для привязки) и
/// единицы без даты производства - без неё не определить партию.
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

/// Дата производства в виде строки прихода - дд.мм.гггг.
String czDate(DateTime d) =>
    '${_two(d.day)}.${_two(d.month)}.${d.year.toString().padLeft(4, '0')}';

String _two(int v) => v.toString().padLeft(2, '0');

/// EAN-13 для привязки по GTIN-14: без ведущего нуля - так и обычный скан ШК той же бутылки
/// найдёт товар (то же правило, что у сервера в скане марки).
String ean13FromGtin(String gtin) =>
    gtin.length == 14 && gtin.startsWith('0') ? gtin.substring(1) : gtin;

/// Тело марок строки для сервера - одинаковое у приёмки и ввода остатков.
Map<String, dynamic> czMarkJson(CzMarkDraft m) => {
  'cis': m.cis,
  'aggregate_code': m.aggregateCode ?? '',
  'discrepancy': m.discrepancy ?? '',
};
