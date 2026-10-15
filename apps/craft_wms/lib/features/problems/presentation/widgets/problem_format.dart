import '../../../../core/gen/strings.g.dart';
import '../../../../core/utils/date_time_format.dart';
import '../../../../core/utils/qty_format.dart';
import '../../../contents/domain/contents_entities.dart';
import '../../../movement/presentation/widgets/move_format.dart';
import '../../domain/problem_models.dart';
import '../../../stock/data/catalog_models.dart';

/// Подписи «Проблем склада» для человека.

/// Причина.
String reasonLabel(ProblemReason r) => switch (r) {
  ProblemReason.breakage => t.problems.reasonBreakage,
  ProblemReason.spoilage => t.problems.reasonSpoilage,
  ProblemReason.expired => t.problems.reasonExpired,
  ProblemReason.foreignMark => t.problems.reasonForeignMark,
  ProblemReason.other => t.problems.reasonOther,
};

/// Короб: «Короб D35F AE87 · Брак» — склад, если не «Основной».
String boxLabel(LoadUnitView box) => withWarehouse(
  t.problems.box(code: boxCode(box.id)),
  box.internalWarehouseName,
);

/// Партия строки со складом: «партия 01.09.2026 · Брак».
String batchLabel(ContentLine line) => withWarehouse(
  t.movement.batch(date: batchDate(line.productionDate)),
  line.internalWarehouseName,
);

/// Место товара: ячейка или «короб … в ячейке».
String placeLabel(Cell cell, LoadUnitView? box) => box == null
    ? cell.address
    : t.movement.placeBox(code: boxCode(box.id), cell: cell.address);

/// Количество с единицей.
String qtyLabel(double qty, String? uom) =>
    '${fmtQty(qty)} ${uom ?? ''}'.trim();
