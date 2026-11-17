import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/load_unit/box_code.dart';
import '../../cz/domain/cz_intake.dart';
import '../../stock/data/catalog_models.dart';

part 'entry_models.freezed.dart';
part 'entry_models.g.dart';

/// Черновик строки ввода: товар + партия (дата выпуска) + количество, россыпью или в коробе
/// прохода. Грань - (товар, дата, короб): один товар может лежать в ячейке разными партиями,
/// россыпью и в коробах. ШК на строке НЕ хранится: привязка `ШК → товар` - факт справочника.
@freezed
abstract class EntryLineDraft with _$EntryLineDraft {
  const EntryLineDraft._();

  const factory EntryLineDraft({
    required Good good,
    required String
    productionDate, // дд.мм.гггг (в UI); в API конвертируется в DD-MM-YYYY
    required double qty,

    /// Короб прохода, в котором лежит товар (ADHOC-46); `null` - россыпь ячейки.
    String? boxId,

    /// Марки ЧЗ строки (ADHOC-46): у маркируемого товара их ровно столько, сколько единиц.
    @Default(<CzMarkDraft>[]) List<CzMarkDraft> marks,
  }) = _EntryLineDraft;

  /// Разбор из слепка незавершённого прохода (P2-03).
  factory EntryLineDraft.fromJson(Map<String, dynamic> json) =>
      _$EntryLineDraftFromJson(json);

  /// Совпадает ли грань строки с заданной.
  bool sameGrain(String goodId, String date, String? boxId) =>
      good.id == goodId && productionDate == date && this.boxId == boxId;

  /// Сколько марок строки расходятся с ЧЗ - уйдут в «Изолятор».
  int get discrepancies => marks.where((m) => m.discrepancy != null).length;
}

/// Короб, заведённый в ячейке прохода (ADHOC-46): свой с QR-ярлыком или короб ЧЗ.
///
/// Ячейка у короба - ячейка прохода, в которой он заведён: короб переезжает только вместе со
/// всей ячейкой («сменить ячейку»). Идентификатор выдаёт терминал - он же в QR ярлыка; ГЕ на
/// сервере появится на финале ввода.
@freezed
abstract class EntryBox with _$EntryBox {
  const EntryBox._();

  const factory EntryBox({required String id, String? czCode}) = _EntryBox;

  factory EntryBox.fromJson(Map<String, dynamic> json) =>
      _$EntryBoxFromJson(json);

  /// Короб ЧЗ: состав закрыт, ярлык не нужен.
  bool get isCz => czCode != null;

  /// Короткий код короба для человека: с ярлыка WMS или хвост SSCC с пометкой «ЧЗ».
  String get code => boxCode(id, czCode: czCode);
}

/// Пройденная (завершённая) ячейка со своими строками, коробами и упаковками ЧЗ - держится
/// локально до финала.
@freezed
abstract class CommittedCell with _$CommittedCell {
  const factory CommittedCell({
    required Cell cell,
    required List<EntryLineDraft> lines,
    @Default(<EntryBox>[]) List<EntryBox> boxes,
    @Default(<CzGroupDraft>[]) List<CzGroupDraft> czGroups,
  }) = _CommittedCell;

  /// Разбор из слепка незавершённого прохода (P2-03).
  factory CommittedCell.fromJson(Map<String, dynamic> json) =>
      _$CommittedCellFromJson(json);
}

/// Тело checkpoint ячейки - `POST /stock-entry/sessions/{id}/cells` (эталон формата -
/// `stock_entry_checkpoint.json` в тестах бэкенда).
///
/// Короба едут только те, в которых есть строки: пустой короб сервер отклонил бы, а ярлык,
/// напечатанный впустую, ГЕ не делает. Дата в UI - с точками, транспорт - DD-MM-YYYY. Привязки
/// ШК с checkpoint'ом не едут (ADHOC-14) - они уходят операциями очереди.
Map<String, dynamic> entryCellBody(CommittedCell c) {
  final used = c.lines.map((l) => l.boxId).nonNulls.toSet();
  return {
    'cell_id': c.cell.id,
    'load_units': [
      for (final b in c.boxes)
        if (used.contains(b.id))
          {'id': b.id, 'kind': 'box', 'cz_code': b.czCode ?? ''},
    ],
    'cz_groups': [
      for (final g in c.czGroups)
        {'code': g.code, 'parent_code': g.parentCode ?? ''},
    ],
    'lines': [
      for (final l in c.lines)
        {
          'good_id': l.good.id,
          'production_date': l.productionDate.replaceAll('.', '-'),
          'qty': l.qty,
          'load_unit_id': l.boxId ?? '',
          'marks': [for (final m in l.marks) czMarkJson(m)],
        },
    ],
    'new_barcodes': const <Map<String, dynamic>>[],
  };
}
